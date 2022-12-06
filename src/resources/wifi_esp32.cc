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
#if defined(CONFIG_TOIT_ENABLE_WIFI)
enum {
  WIFI_CONNECTED    = 1 << 0,
  WIFI_IP_ASSIGNED  = 1 << 1,
  WIFI_IP_LOST      = 1 << 2,
  WIFI_DISCONNECTED = 1 << 3,
  WIFI_RETRY        = 1 << 4,
  WIFI_SCAN_DONE    = 1 << 5,
};

const int kInvalidWifi = -1;

// Only allow one instance of WiFi running.
ResourcePool<int, kInvalidWifi> wifi_pool(
  0
);

class WifiResourceGroup : public ResourceGroup {
 public:
  TAG(WifiResourceGroup);
  WifiResourceGroup(Process* process, SystemEventSource* event_source, int id, esp_netif_t* netif)
      : ResourceGroup(process, event_source)
      , id_(id)
      , netif_(netif) {
    clear_ip_address();
  }

  uint32 ip_address() const { return ip_address_; }
  bool has_ip_address() const { return ip_address_ != 0; }

  void set_ip_address(uint32 address) { ip_address_ = address; }
  void clear_ip_address() { ip_address_ = 0; }

  esp_err_t connect(const char* ssid, const char* password) {
    // Configure the WiFi to _start_ the channel scan from the last connected channel.
    // If there has been no previous connection, then the channel is 0 which causes a normal scan.
    uint8 channel = RtcMemory::wifi_channel();
    if (channel > 13) {
      channel = 0;
      RtcMemory::set_wifi_channel(0);
    }

    esp_err_t err = esp_wifi_set_mode(WIFI_MODE_STA);
    if (err != ESP_OK) return err;

    wifi_config_t config;
    memset(&config, 0, sizeof(config));
    strncpy(char_cast(config.sta.ssid), ssid, sizeof(config.sta.ssid) - 1);
    strncpy(char_cast(config.sta.password), password, sizeof(config.sta.password) - 1);
    config.sta.channel = channel;
    err = esp_wifi_set_config(WIFI_IF_STA, &config);
    if (err != ESP_OK) return err;

    err = esp_wifi_start();
    if (err != ESP_OK) return err;

    return esp_wifi_connect();
  }

  esp_err_t establish(const char* ssid, const char* password, bool broadcast, int channel) {
    esp_err_t err = esp_wifi_set_mode(WIFI_MODE_AP);
    if (err != ESP_OK) return err;

    wifi_config_t config;
    memset(&config, 0, sizeof(config));
    strncpy(char_cast(config.ap.ssid), ssid, sizeof(config.ap.ssid) - 1);
    strncpy(char_cast(config.ap.password), password, sizeof(config.ap.password) - 1);
    config.ap.channel = channel;
    config.ap.authmode = WIFI_AUTH_WPA2_PSK;
    config.ap.ssid_hidden = broadcast ? 0 : 1;
    config.ap.max_connection = 4;
    config.ap.beacon_interval = 100;
    config.ap.pairwise_cipher = WIFI_CIPHER_TYPE_CCMP;
    err = esp_wifi_set_config(WIFI_IF_AP, &config);
    if (err != ESP_OK) return err;

    return esp_wifi_start();
  }

  esp_err_t init_scan(void) {
    esp_err_t err = esp_wifi_set_mode(WIFI_MODE_STA);
    if (err != ESP_OK) return err;

    return esp_wifi_start();
  }

  esp_err_t start_scan(bool passive, int channel, uint32_t period_ms) {
    wifi_scan_config_t config{};

    config.channel = channel;
    if (passive) {
      config.scan_type = WIFI_SCAN_TYPE_PASSIVE;
      config.scan_time.passive = period_ms;
    } else {
      config.scan_time.active.max = period_ms;
      config.scan_time.active.min = period_ms;
    }

    return esp_wifi_scan_start(&config, false);
  }

  ~WifiResourceGroup() {
    esp_err_t err = esp_wifi_deinit();
    if (err == ESP_ERR_WIFI_NOT_STOPPED) {
      FATAL_IF_NOT_ESP_OK(esp_wifi_stop());
      FATAL_IF_NOT_ESP_OK(esp_wifi_deinit());
    } else {
      FATAL_IF_NOT_ESP_OK(err);
    }

    esp_netif_destroy_default_wifi(netif_);
    wifi_pool.put(id_);
  }

  uint32 on_event(Resource* resource, word data, uint32 state);

 private:
  int id_;
  esp_netif_t* netif_;
  uint32 ip_address_;

  uint32 on_event_wifi(Resource* resource, word data, uint32 state);
  uint32 on_event_ip(Resource* resource, word data, uint32 state);

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
      , disconnect_reason_(WIFI_REASON_UNSPECIFIED) {}

  ~WifiEvents() {
    FATAL_IF_NOT_ESP_OK(esp_wifi_stop());
  }

  uint8 disconnect_reason() const { return disconnect_reason_; }
  void set_disconnect_reason(uint8 reason) { disconnect_reason_ = reason; }

 private:
  friend class WifiResourceGroup;
  uint8 disconnect_reason_;
};

class WifiIpEvents : public SystemResource {
 public:
  TAG(WifiIpEvents);
  explicit WifiIpEvents(WifiResourceGroup* group)
      : SystemResource(group, IP_EVENT) {}
};

uint32 WifiResourceGroup::on_event_wifi(Resource* resource, word data, uint32 state) {
  SystemEvent* system_event = reinterpret_cast<SystemEvent*>(data);

  switch (system_event->id) {
    case WIFI_EVENT_STA_CONNECTED:
      state |= WIFI_CONNECTED;
      cache_wifi_channel();
      break;

    case WIFI_EVENT_STA_DISCONNECTED: {
      uint8 reason = reinterpret_cast<wifi_event_sta_disconnected_t*>(system_event->event_data)->reason;
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
      break;

    case WIFI_EVENT_SCAN_DONE: {
      state |= WIFI_SCAN_DONE;
      break;
    }

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

    case WIFI_EVENT_AP_START:
      state |= WIFI_CONNECTED;
      break;

    case WIFI_EVENT_AP_STOP:
      state |= WIFI_DISCONNECTED;
      break;

    case WIFI_EVENT_AP_STACONNECTED:
      break;

    case WIFI_EVENT_AP_STADISCONNECTED:
      break;

    default:
      printf(
#ifdef CONFIG_IDF_TARGET_ESP32C3
          "unhandled Wi-Fi event: %lu\n",
#else
          "unhandled Wi-Fi event: %d\n",
#endif
          system_event->id
      );
  }

  return state;
}

uint32 WifiResourceGroup::on_event_ip(Resource* resource, word data, uint32 state) {
  SystemEvent* system_event = reinterpret_cast<SystemEvent*>(data);

  switch (system_event->id) {
    case IP_EVENT_STA_GOT_IP: {
      ip_event_got_ip_t* event = reinterpret_cast<ip_event_got_ip_t*>(system_event->event_data);
      set_ip_address(event->ip_info.ip.addr);
      state |= WIFI_IP_ASSIGNED;
      break;
    }

    case IP_EVENT_STA_LOST_IP: {
      state |= WIFI_IP_LOST;
      clear_ip_address();
      break;
    }

    default:
      printf(
#ifdef CONFIG_IDF_TARGET_ESP32C3
          "unhandled IP event: %lu\n",
#else
          "unhandled IP event: %d\n",
#endif
          system_event->id
      );
  }

  return state;
}

uint32 WifiResourceGroup::on_event(Resource* resource, word data, uint32 state) {
  SystemEvent* system_event = reinterpret_cast<SystemEvent*>(data);

  if (system_event->base == WIFI_EVENT) {
    state = on_event_wifi(resource, data, state);
  } else if (system_event->base == IP_EVENT) {
    state = on_event_ip(resource, data, state);
  }

  return state;
}

MODULE_IMPLEMENTATION(wifi, MODULE_WIFI)

PRIMITIVE(init) {
  ARGS(bool, ap);

  HeapTagScope scope(ITERATE_CUSTOM_TAGS + WIFI_MALLOC_TAG);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  int id = wifi_pool.any();
  if (id == kInvalidWifi) OUT_OF_BOUNDS;

  // We cannot use the esp_netif_create_default_wifi_xxx() functions,
  // because they do not correctly check for malloc failure.
  esp_netif_t* netif = null;
  if (ap) {
    esp_netif_config_t netif_ap_config = ESP_NETIF_DEFAULT_WIFI_AP();
    netif = esp_netif_new(&netif_ap_config);
  } else {
    esp_netif_config_t netif_sta_config = ESP_NETIF_DEFAULT_WIFI_STA();
    netif = esp_netif_new(&netif_sta_config);
  }

  if (!netif) {
    wifi_pool.put(id);
    MALLOC_FAILED;
  }

  if (ap) {
    esp_netif_attach_wifi_ap(netif);
    esp_wifi_set_default_wifi_ap_handlers();
  } else {
    esp_netif_attach_wifi_station(netif);
    esp_wifi_set_default_wifi_sta_handlers();
  }

  esp_err_t err = nvs_flash_init();
  if (err != ESP_OK) {
    esp_netif_destroy_default_wifi(netif);
    wifi_pool.put(id);
    return Primitive::os_error(err, process);
  }

  // Create a thread that takes care of logging into the Wifi AP.
  wifi_init_config_t init_config = WIFI_INIT_CONFIG_DEFAULT();
  init_config.nvs_enable = 0;
  if (!OS::use_spiram_for_heap()) {
    // Configuring ESP-IDF for SPIRAM support dramatically increases the amount
    // of memory that the Wifi uses.  If the SPIRAM is not actually present on
    // the current board we need to set the values back to zero.
    init_config.cache_tx_buf_num = 0;
    init_config.feature_caps &= ~CONFIG_FEATURE_CACHE_TX_BUF_BIT;
  }
  err = esp_wifi_init(&init_config);
  if (err != ESP_OK) {
    esp_netif_destroy_default_wifi(netif);
    wifi_pool.put(id);
    return Primitive::os_error(err, process);
  }

  err = esp_wifi_set_storage(WIFI_STORAGE_RAM);
  if (err != ESP_OK) {
    FATAL_IF_NOT_ESP_OK(esp_wifi_deinit());
    esp_netif_destroy_default_wifi(netif);
    wifi_pool.put(id);
    return Primitive::os_error(err, process);
  }

  WifiResourceGroup* resource_group = _new WifiResourceGroup(
      process, SystemEventSource::instance(), id, netif);
  if (!resource_group) {
    FATAL_IF_NOT_ESP_OK(esp_wifi_deinit());
    esp_netif_destroy_default_wifi(netif);
    wifi_pool.put(id);
    MALLOC_FAILED;
  }

  if (ap) {
    esp_netif_ip_info_t ip;
    if (esp_netif_get_ip_info(netif, &ip) == ESP_OK) {
      resource_group->set_ip_address(ip.ip.addr);
    }
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

PRIMITIVE(establish) {
  ARGS(WifiResourceGroup, group, cstring, ssid, cstring, password, bool, broadcast, int, channel);
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + WIFI_MALLOC_TAG);

  if (ssid == null || password == null) {
    INVALID_ARGUMENT;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  WifiEvents* wifi = _new WifiEvents(group);
  if (wifi == null) MALLOC_FAILED;

  group->register_resource(wifi);

  esp_err_t err = group->establish(ssid, password, broadcast, channel);
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

  WifiIpEvents* ip_events = _new WifiIpEvents(group);
  if (ip_events == null) MALLOC_FAILED;

  group->register_resource(ip_events);
  proxy->set_external_address(ip_events);
  return proxy;
}

PRIMITIVE(disconnect) {
  ARGS(WifiResourceGroup, group, WifiEvents, wifi);

  group->unregister_resource(wifi);
  wifi_proxy->clear_external_address();
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
  ARGS(WifiResourceGroup, group);
  if (!group->has_ip_address()) {
    return process->program()->null_object();
  }

  ByteArray* result = process->object_heap()->allocate_internal_byte_array(4);
  if (!result) ALLOCATION_FAILED;
  ByteArray::Bytes bytes(result);
  Utils::write_unaligned_uint32_le(bytes.address(), group->ip_address());
  return result;
}

PRIMITIVE(init_scan) {
  ARGS(WifiResourceGroup, group)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  WifiEvents* wifi = _new WifiEvents(group);
  if (wifi == null) MALLOC_FAILED;

  group->register_resource(wifi);

  esp_err_t ret = group->init_scan();
  if (ret != ESP_OK) {
    group->unregister_resource(wifi);
    return Primitive::os_error(ret, process);
  }

  proxy->set_external_address(wifi);
  return proxy;
}

PRIMITIVE(start_scan) {
  ARGS(WifiResourceGroup, group, int, channel, bool, passive, int, period_ms);

  esp_err_t ret = group->start_scan(passive, channel, period_ms);
  if (ret != ESP_OK) {
    return Primitive::os_error(ret, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(read_scan) {
  ARGS(WifiResourceGroup, group);

  uint16_t count;
  esp_err_t ret = esp_wifi_scan_get_ap_num(&count);
  if (ret != ESP_OK) return Primitive::os_error(ret, process);

  if (count == 0) return process->program()->empty_array();

  size_t size = count * sizeof(wifi_ap_record_t);
  MallocedBuffer data_buffer(size);
  if (!data_buffer.has_content()) MALLOC_FAILED;

  uint16_t get_count = count;
  wifi_ap_record_t* ap_record = reinterpret_cast<wifi_ap_record_t*>(data_buffer.content());
  ret = esp_wifi_scan_get_ap_records(&get_count, ap_record);
  if (ret != ESP_OK) return Primitive::os_error(ret, process);

  const size_t element_count = 5;
  size = element_count * get_count;
  Array* ap_array = process->object_heap()->allocate_array(size, Smi::zero());
  if (ap_array == null) ALLOCATION_FAILED;

  for (int i = 0; i < get_count; i++) {
    size_t offset = i * element_count;
    String* ssid = process->allocate_string((char *)ap_record[i].ssid);
    if (ssid == null) ALLOCATION_FAILED;

    size_t bssid_size = 6;
    ByteArray* bssid = process->allocate_byte_array(bssid_size);
    if (bssid == null) ALLOCATION_FAILED;

    memcpy(ByteArray::Bytes(bssid).address(), ap_record[i].bssid, bssid_size);

    ap_array->at_put(offset, ssid);
    ap_array->at_put(offset + 1, bssid);
    ap_array->at_put(offset + 2, Smi::from(ap_record[i].rssi));
    ap_array->at_put(offset + 3, Smi::from(ap_record[i].authmode));
    ap_array->at_put(offset + 4, Smi::from(ap_record[i].primary));
  }

  return ap_array;
}

PRIMITIVE(get_ap_info) {
  ARGS(WifiResourceGroup, group);

  wifi_ap_record_t ap_record;
  esp_err_t ret = esp_wifi_sta_get_ap_info(&ap_record);
  if (ret != OK) return Primitive::os_error(ret, process);

  const size_t element_count = 5;
  Array* ap_array = process->object_heap()->allocate_array(element_count, Smi::zero());
  if (ap_array == null) ALLOCATION_FAILED;

  String* ssid = process->allocate_string((char *)ap_record.ssid);
  if (ssid == null) ALLOCATION_FAILED;

  size_t bssid_size = 6;
  ByteArray* bssid = process->allocate_byte_array(bssid_size);
  if (bssid == null) ALLOCATION_FAILED;

  memcpy(ByteArray::Bytes(bssid).address(), ap_record.bssid, bssid_size);

  ap_array->at_put(0, ssid);
  ap_array->at_put(1, bssid);
  ap_array->at_put(2, Smi::from(ap_record.rssi));
  ap_array->at_put(3, Smi::from(ap_record.authmode));
  ap_array->at_put(4, Smi::from(ap_record.primary));

  return ap_array;
}
#endif // CONFIG_TOIT_ENABLE_WIFI
} // namespace toit

#endif // TOIT_FREERTOS
