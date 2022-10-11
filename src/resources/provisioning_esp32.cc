// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "../top.h"

#if defined(TOIT_FREERTOS) && defined(CONFIG_TOIT_ENABLE_PROVISIONING)

#include <freertos/FreeRTOS.h>
#include <freertos/event_groups.h>

#include <esp_wifi.h>
#include <wifi_provisioning/manager.h>
#include <wifi_provisioning/scheme_ble.h>
#include <qrcode.h>

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"

namespace toit {

enum {
  WIFI_CONNECTED = 1 << 0,
  GOT_IP         = 1 << 1,   
};

const int kInvalidProvisioning = -1;

// Only allow one instance of provisioning running.
ResourcePool<int, kInvalidProvisioning> provisioning_pool(
  0
);

class ProvisioningResourceGroup : public ResourceGroup {
 public:
  TAG(ProvisioningResourceGroup);

  ProvisioningResourceGroup(Process* process, SystemEventSource* event_source);
  ~ProvisioningResourceGroup();

  bool IsProvisioned(void);
  void GetMacAddr(uint8_t *mac_addr);
  void Start(const char *name, const char *pop, const char *key, uint8_t *uuid);
  void QRCodePrintString(const char *data);
  void ConnectToAP(void);
  bool WaitForDone(int timeout_ms);
  void GetIPAddr(uint8_t *ip_addr);

  uint32_t on_event(Resource* resource, word data, uint32_t state);

 private:
  static const EventBits_t PROV_DONE_EVENT = BIT0;
  uint32_t _retries;
  EventGroupHandle_t wifi_event_group;
  esp_netif_t *netif;
  bool provisioned;

  std::string service_name;
  std::string service_pop;
  std::string service_key;
};

class ProvisioningEvent : public SystemResource {
 public:
  TAG(WifiEvents);
  explicit ProvisioningEvent(ProvisioningResourceGroup* group, esp_event_base_t event)
      : SystemResource(group, event) {
  }

  ~ProvisioningEvent() { }

 private:
  friend class ProvisioningResourceGroup;
};

ProvisioningResourceGroup::ProvisioningResourceGroup(Process* process, SystemEventSource* event_source)
  : ResourceGroup(process, event_source),
    _retries(0)
{
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    wifi_prov_mgr_config_t config;

    FATAL_IF_NOT_ESP_OK(esp_wifi_init(&cfg));

    wifi_event_group = xEventGroupCreate();
    ASSERT(wifi_event_group);

    config.scheme = wifi_prov_scheme_ble;
    config.scheme_event_handler = WIFI_PROV_EVENT_HANDLER_NONE;
    config.app_event_handler = WIFI_PROV_EVENT_HANDLER_NONE;
    FATAL_IF_NOT_ESP_OK(wifi_prov_mgr_init(config));

    IsProvisioned();
}

ProvisioningResourceGroup::~ProvisioningResourceGroup() {
  wifi_prov_mgr_deinit();
  vEventGroupDelete(wifi_event_group);
}

void ProvisioningResourceGroup::Start(const char *name, const char *pop, const char *key, uint8_t *uuid) {
  service_name = name;
  service_pop  = pop;
  service_key  = key;

  FATAL_IF_NOT_ESP_OK(wifi_prov_scheme_ble_set_service_uuid(uuid));  
  
  FATAL_IF_NOT_ESP_OK(esp_netif_init());
  netif = esp_netif_create_default_wifi_sta();

  wifi_prov_security_t security = WIFI_PROV_SECURITY_1;
  FATAL_IF_NOT_ESP_OK(wifi_prov_mgr_start_provisioning(security, service_pop.c_str(), service_name.c_str(), service_key.c_str()));
}

void ProvisioningResourceGroup::QRCodePrintString(const char *data) {
  esp_qrcode_config_t cfg = ESP_QRCODE_CONFIG_DEFAULT();
  esp_qrcode_generate(&cfg, data);
}

void ProvisioningResourceGroup::ConnectToAP(void) {
  FATAL_IF_NOT_ESP_OK(esp_wifi_set_mode(WIFI_MODE_STA));
  FATAL_IF_NOT_ESP_OK(esp_wifi_start());
}

bool ProvisioningResourceGroup::WaitForDone(int timeout_ms) {
  EventBits_t uxBits = xEventGroupWaitBits(wifi_event_group, PROV_DONE_EVENT, false, true, pdMS_TO_TICKS(timeout_ms));
  return uxBits & PROV_DONE_EVENT ? true : false;
}

uint32_t ProvisioningResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
  SystemEvent* system_event = reinterpret_cast<SystemEvent*>(data);
  if (system_event->base == WIFI_PROV_EVENT) {
    switch (system_event->id) {
      case WIFI_PROV_CRED_FAIL: {
        _retries++;
        if (_retries >= 10) {
            wifi_prov_mgr_reset_sm_state_on_failure();
            _retries = 0;
        }
        break;
      }
      case WIFI_PROV_CRED_SUCCESS:
        _retries = 0;
        break;
      case WIFI_PROV_END:
        if (!provisioned) {
          xEventGroupSetBits(wifi_event_group, PROV_DONE_EVENT);
        }
        break;
      default:
        break;
    }
  } else if (system_event->base == WIFI_EVENT) {
    switch(system_event->id) {
      case WIFI_EVENT_STA_START:
        esp_wifi_connect();
        break;
      case WIFI_EVENT_STA_CONNECTED:
        state |= WIFI_CONNECTED;
        break;
      case WIFI_EVENT_STA_DISCONNECTED:
        xEventGroupClearBits(wifi_event_group, PROV_DONE_EVENT);
        state &= ~(WIFI_CONNECTED | GOT_IP);
        esp_wifi_connect();
      default:
        break;
    }
  } else if (system_event->base == IP_EVENT) {
    switch (system_event->id) {
      case IP_EVENT_STA_GOT_IP:
        state |= GOT_IP;
        if (provisioned) {
          xEventGroupSetBits(wifi_event_group, PROV_DONE_EVENT);
        }
      default:
        break;
    }
  }

  return state;
}

bool ProvisioningResourceGroup::IsProvisioned(void) {
  provisioned = false;
  FATAL_IF_NOT_ESP_OK(wifi_prov_mgr_is_provisioned(&provisioned));
  return provisioned;
}

void ProvisioningResourceGroup::GetMacAddr(uint8_t *mac_addr) {
  FATAL_IF_NOT_ESP_OK(esp_wifi_get_mac(WIFI_IF_STA, mac_addr));
}

void ProvisioningResourceGroup::GetIPAddr(uint8_t *ip_addr) {
  esp_netif_ip_info_t ip;
  FATAL_IF_NOT_ESP_OK(esp_netif_get_ip_info(netif, &ip));

  memcpy(ip_addr, &ip.ip, 4);
}

MODULE_IMPLEMENTATION(provisioning, MODULE_PROVISIONING)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    ALLOCATION_FAILED;
  }

  int id = provisioning_pool.any();
  if (id == kInvalidProvisioning) ALREADY_IN_USE;

  ProvisioningResourceGroup* group = _new ProvisioningResourceGroup(
      process, SystemEventSource::instance());
  if (!group) {
    provisioning_pool.put(id);
    MALLOC_FAILED;
  }

  ProvisioningEvent *event = _new ProvisioningEvent(group, WIFI_PROV_EVENT);
  if (!event) MALLOC_FAILED;
  group->register_resource(event);

  event = _new ProvisioningEvent(group, WIFI_EVENT);
  if (!event) MALLOC_FAILED;
  group->register_resource(event);

  event = _new ProvisioningEvent(group, IP_EVENT);
  if (!event) MALLOC_FAILED;
  group->register_resource(event);

  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(is_provisioned) {
  ARGS(ProvisioningResourceGroup, group);

  bool provisioned = group->IsProvisioned();

  return provisioned ? process->program()->true_object() :
                       process->program()->false_object();
}

PRIMITIVE(get_mac_addr) {
  ARGS(ProvisioningResourceGroup, group);

  uint8_t mac_addr[6];
  group->GetMacAddr(mac_addr);
  ByteArray *result = process->allocate_byte_array(sizeof(mac_addr));
  if (!result) ALLOCATION_FAILED;

  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), mac_addr, sizeof(mac_addr));

  return result;
}

PRIMITIVE(start) {
  ARGS(ProvisioningResourceGroup, group, cstring, name, cstring, pop, cstring, key, Blob, uuid);

  group->Start(name, pop, key, (uint8_t *)uuid.address());

  return process->program()->null_object();
}

PRIMITIVE(qrcode_print_string) {
  ARGS(ProvisioningResourceGroup, group, cstring, data);

  group->QRCodePrintString(data);

  return process->program()->null_object();
}

PRIMITIVE(connect_to_ap) {
  ARGS(ProvisioningResourceGroup, group);

  group->ConnectToAP();

  return process->program()->null_object();
}

PRIMITIVE(wait_for_done) {
  ARGS(ProvisioningResourceGroup, group, int, timeout_ms);

  bool ret = group->WaitForDone(timeout_ms);

  return ret ? process->program()->true_object() :
               process->program()->false_object(); 
}

PRIMITIVE(get_ip_addr) {
  ARGS(ProvisioningResourceGroup, group);

  uint8_t ip_addr[4];
  group->GetIPAddr(ip_addr);
  ByteArray *result = process->allocate_byte_array(sizeof(ip_addr));
  if (!result) ALLOCATION_FAILED;

  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), ip_addr, sizeof(ip_addr));

  return result;
}

PRIMITIVE(deinit) {
  ARGS(ProvisioningResourceGroup, group);

  group->tear_down();
  group_proxy->clear_external_address();
  return process->program()->null_object();
}

} // namespace toit

#endif
