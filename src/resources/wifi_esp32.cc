// Copyright (C) 2018 Toitware ApS.
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

#ifdef TOIT_FREERTOS

#include <esp_wifi.h>
#include <nvs_flash.h>
#include <lwip/sockets.h>

#include "../resource.h"
#include "../rtc_memory_esp32.h"
#include "../objects.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../primitive.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"

namespace toit {

enum {
  WIFI_CONNECTED    = 1 << 0,
  WIFI_IP_ASSIGNED  = 1 << 1,
  WIFI_IP_LOST      = 1 << 2,
  WIFI_DISCONNECTED = 1 << 3,
  WIFI_RETRY        = 1 << 4,
};

const int kInvalidWifi = -1;

// Only allow one instance of WiFi running.
ResourcePool<int, kInvalidWifi> wifi_pool(
  0
);

class WifiResourceGroup : public ResourceGroup {
 public:
  TAG(WifiResourceGroup);
  WifiResourceGroup(Process* process, SystemEventSource* event_source, int id,
                    esp_netif_t* netif)
      : ResourceGroup(process, event_source)
      , _id(id)
      , _netif(netif) {
  }

  esp_err_t connect(const char* ssid, const char* password) {
    wifi_config_t config;
    memset(&config, 0, sizeof(config));
    strncpy(char_cast(config.sta.ssid), ssid, sizeof(config.sta.ssid));
    strncpy(char_cast(config.sta.password), password, sizeof(config.sta.password));
    // Configure the WiFi to _start_ the channel scan from the last connected channel.
    // If there has been no previous connection, then the channel is 0 which causes a normal scan.
    uint8 channel = RtcMemory::wifi_channel();
    if (!(0 <= channel && channel <= 13)) {
      channel = 0;
      RtcMemory::set_wifi_channel(0);
    }
    config.sta.channel = channel;
    esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &config);
    if (err != ESP_OK) return err;
    return esp_wifi_start();
  }

  int rssi() {
    wifi_ap_record_t ap_info;
    esp_err_t err = esp_wifi_sta_get_ap_info(&ap_info);
    if (err != ERR_OK) return 0;
    return ap_info.rssi;
  }

  ~WifiResourceGroup() {
    FATAL_IF_NOT_ESP_OK(esp_wifi_deinit());
    esp_netif_destroy(_netif);
    wifi_pool.put(_id);
  }

  uint32_t on_event(Resource* resource, word data, uint32_t state);

 private:
  int _id;
  esp_netif_t *_netif;

  void cache_wifi_channel() {
    uint8 primary_channel;
    wifi_second_chan_t secondary_channel;
    if (esp_wifi_get_channel(&primary_channel, &secondary_channel) != ESP_OK) return;

    RtcMemory::set_wifi_channel(primary_channel);
  }
 };


class WifiEvents : public SystemResource {
 public:
  TAG(WifiEvents);
  explicit WifiEvents(WifiResourceGroup* group)
      : SystemResource(group, WIFI_EVENT)
      , _disconnect_reason(WIFI_REASON_UNSPECIFIED) {
  }

  ~WifiEvents() {
    FATAL_IF_NOT_ESP_OK(esp_wifi_stop());
  }

  uint8 disconnect_reason() const { return _disconnect_reason; }
  void set_disconnect_reason(uint8 reason) { _disconnect_reason = reason; }

 private:
  friend class WifiResourceGroup;
  uint8 _disconnect_reason;
};

class IPEvents : public SystemResource {
 public:
  TAG(IPEvents);
  explicit IPEvents(WifiResourceGroup* group)
      : SystemResource(group, IP_EVENT)
      , _ip((char*)calloc(1, 16)) {}

  ~IPEvents() {
    free(_ip);
  }

  const char* ip() const {
    return _ip;
  }

 private:
  friend class WifiResourceGroup;
  char* _ip;
};

uint32_t WifiResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
  SystemEvent* system_event = reinterpret_cast<SystemEvent*>(data);
  switch (system_event->id) {
    case WIFI_EVENT_STA_CONNECTED:
      state |= WIFI_CONNECTED;
      cache_wifi_channel();
      break;

    case WIFI_EVENT_STA_DISCONNECTED: {
      uint8_t reason = reinterpret_cast<wifi_event_sta_disconnected_t*>(system_event->event_data)->reason;
      switch (reason) {
        case WIFI_REASON_ASSOC_LEAVE:
        case WIFI_REASON_ASSOC_EXPIRE:
        case WIFI_REASON_AUTH_EXPIRE:
          state |= WIFI_RETRY;
          break;
        default:
          state |= WIFI_DISCONNECTED;
          break;
      }
      static_cast<WifiEvents*>(resource)->set_disconnect_reason(reason);
      break;
    }

    case WIFI_EVENT_STA_START:
      FATAL_IF_NOT_ESP_OK(esp_wifi_connect());
      break;

    case WIFI_EVENT_STA_STOP:
      break;

    case WIFI_EVENT_STA_BEACON_TIMEOUT:
      // The beacon timeout mechanism is used by ESP32 station to detect whether the AP
      // is alive or not. If the station continuously loses 60 beacons of the connected
      // AP, the beacon timeout happens.
      //
      // After the beacon times out, the station sends 5 probe requests to the AP. If
      // still no probe response or beacon is received from AP, the station disconnects
      // from the AP and raises the WIFI_EVENT_STA_DISCONNECTED event.
      break;

    case IP_EVENT_STA_GOT_IP: {
      ip_event_got_ip_t* event = reinterpret_cast<ip_event_got_ip_t*>(system_event->event_data);
      uint32_t addr = event->ip_info.ip.addr;
      sprintf(
          static_cast<IPEvents*>(resource)->_ip,
#ifdef CONFIG_IDF_TARGET_ESP32C3
          "%lu.%lu.%lu.%lu",
#else
          "%d.%d.%d.%d",
#endif
          (addr >> 0) & 0xff,
          (addr >> 8) & 0xff,
          (addr >> 16) & 0xff,
          (addr >> 24) & 0xff);
      state |= WIFI_IP_ASSIGNED;
      break;
    }

    case IP_EVENT_STA_LOST_IP:
      state |= WIFI_IP_LOST;
      break;

    default:
      printf(
#ifdef CONFIG_IDF_TARGET_ESP32C3
          "unhandled WiFi event: %lu\n",
#else
          "unhandled WiFi event: %d\n",
#endif
          system_event->id
      );
  }

  return state;
}

MODULE_IMPLEMENTATION(wifi, MODULE_WIFI)

PRIMITIVE(init) {
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + WIFI_MALLOC_TAG);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  int id = wifi_pool.any();
  if (id == kInvalidWifi) OUT_OF_BOUNDS;

  esp_netif_t* netif = esp_netif_create_default_wifi_sta();
  if (!netif) {
    wifi_pool.put(id);
    MALLOC_FAILED;
  }

  // Create a thread that takes care of logging into the Wifi AP.
  wifi_init_config_t init_config = WIFI_INIT_CONFIG_DEFAULT();
  init_config.nvs_enable = 0;
  esp_err_t err = esp_wifi_init(&init_config);
  if (err != ESP_OK) {
    esp_netif_destroy(netif);
    wifi_pool.put(id);
    return Primitive::os_error(err, process);
  }

  err = esp_wifi_set_storage(WIFI_STORAGE_RAM);
  if (err == ESP_OK) {
    err = esp_wifi_set_mode(WIFI_MODE_STA);
  }
  if (err != ESP_OK) {
    FATAL_IF_NOT_ESP_OK(esp_wifi_deinit());
    esp_netif_destroy(netif);
    wifi_pool.put(id);
    return Primitive::os_error(err, process);
  }

  WifiResourceGroup* resource_group = _new WifiResourceGroup(process, SystemEventSource::instance(), id, netif);
  if (!resource_group) {
    FATAL_IF_NOT_ESP_OK(esp_wifi_deinit());
    esp_netif_destroy(netif);
    wifi_pool.put(id);
    MALLOC_FAILED;
  }

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(WifiResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(connect) {
  ARGS(WifiResourceGroup, group, cstring, ssid, cstring, password);
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + WIFI_MALLOC_TAG);

  if (ssid == null || password == null) {
    INVALID_ARGUMENT;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  WifiEvents* wifi = _new WifiEvents(group);
  if (wifi == null) MALLOC_FAILED;

  group->register_resource(wifi);

  esp_err_t err = group->connect(ssid, password);
  if (err != ESP_OK) {
    group->unregister_resource(wifi);
    return Primitive::os_error(err, process);
  }

  proxy->set_external_address(wifi);
  return proxy;
}

PRIMITIVE(setup_ip) {
  ARGS(WifiResourceGroup, group);
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + WIFI_MALLOC_TAG);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  IPEvents* ip_events = _new IPEvents(group);
  if (ip_events == null) MALLOC_FAILED;

  group->register_resource(ip_events);

  proxy->set_external_address(ip_events);
  return proxy;
}


PRIMITIVE(disconnect) {
  ARGS(WifiResourceGroup, group, WifiEvents, wifi);

  group->unregister_resource(wifi);

  return process->program()->null_object();
}

PRIMITIVE(disconnect_reason) {
  ARGS(WifiEvents, wifi);
  switch (wifi->disconnect_reason()) {
    case WIFI_REASON_ASSOC_EXPIRE:
    case WIFI_REASON_ASSOC_LEAVE:
      return process->allocate_string_or_error("session expired");
    case WIFI_REASON_AUTH_EXPIRE:
      return process->allocate_string_or_error("timeout");
    case WIFI_REASON_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_AUTH_FAIL:
      return process->allocate_string_or_error("bad authentication");
    case WIFI_REASON_NO_AP_FOUND:
      return process->allocate_string_or_error("access point not found");
    default:
      char reason[32] = {0};
      sprintf(reason, "unknown reason (%d)", wifi->disconnect_reason());
      return process->allocate_string_or_error(reason);
  }
}

PRIMITIVE(get_ip) {
  ARGS(IPEvents, ip);
  return process->allocate_string_or_error(ip->ip());
}

PRIMITIVE(get_rssi) {
  ARGS(WifiResourceGroup, wifi);
  int rssi = wifi->rssi();
  if (rssi == 0) return process->program()->null_object();
  return Smi::from(rssi);
}

} // namespace toit

#endif // TOIT_FREERTOS
