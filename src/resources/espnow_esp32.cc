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

#if defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_ESPNOW)

#include <esp_wifi.h>
#include <esp_event.h>
#include <esp_netif.h>
#include <esp_now.h>
#include <esp_log.h>

#include "wifi_espnow_esp32.h"

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"
#include "../event_sources/ev_queue_esp32.h"

#define ESPNOW_RX_DATAGRAM_LEN_MAX  250
#define ESPNOW_RX_DATAGRAM_NUM 8
// The size of the event queue.
// Can contain up to ESPNOW_RX_DATAGRAM_NUM receival events, and then
// one for informing that a sent message was handled.
// We rely on the fact that sending is blocking until it has been sent.
// As such there can only be one additional event in the queue.
#define ESPNOW_EVENT_NUM (ESPNOW_RX_DATAGRAM_NUM + 1)

namespace toit {

class SpinLocker {
 public:
  explicit SpinLocker(spinlock_t* spinlock) : spinlock_(spinlock) { portENTER_CRITICAL(spinlock_); }
  ~SpinLocker() { portEXIT_CRITICAL(spinlock_); }
 private:
  spinlock_t* spinlock_;
};

struct Datagram {
  word len;
  uint8 mac[6];
  uint8 buffer[ESPNOW_RX_DATAGRAM_LEN_MAX];
};

class DatagramPool {
 public:
  DatagramPool() {
    spinlock_initialize(&spinlock_);
    for (int i = 0; i < ESPNOW_RX_DATAGRAM_NUM; i++) {
      ASSERT(datagrams_[i] == NULL);
    }
  }

  ~DatagramPool() {
    for (int i = 0; i < ESPNOW_RX_DATAGRAM_NUM; i++) {
      // If we didn't manage to allocate all datagrams, then some entries
      // will be 'null', as the 'datagrams_' array is initialized to null.
      free(datagrams_[i]);
    }
  }

  Object* init() {
    // We allocate the datagrams individually instead of as
    // a big array, so they don't need a contiguous memory area.
    for (int i = 0; i < ESPNOW_RX_DATAGRAM_NUM; i++) {
      auto datagram = unvoid_cast<Datagram*>(malloc(sizeof(Datagram)));
      if (datagram == null) {
        FAIL(MALLOC_FAILED);
      }
      datagrams_[i] = datagram;
    }
    return null;
  }

  Datagram* take() {
    SpinLocker locker(&spinlock_);
    int mask = 1;
    for (int i = 0; i < ESPNOW_RX_DATAGRAM_NUM; i++) {
      if ((used_ & mask) == 0) {
        used_ = used_ | mask;
        return datagrams_[i];
      }
      mask <<= 1;
    }
    return null;
  }

  void release(Datagram* datagram) {
    int mask = 1;
    for (int i = 0; i < ESPNOW_RX_DATAGRAM_NUM; i++) {
      if (datagrams_[i] == datagram) {
        SpinLocker locker(&spinlock_);
        used_ = used_ & ~mask;
        return;
      }
      mask <<= 1;
    }
  }

 private:
  spinlock_t spinlock_{};
  struct Datagram* datagrams_[ESPNOW_RX_DATAGRAM_NUM] = {};
  volatile int used_ = 0;
};

// These constants must be synchronized with the Toit code.
const int kDataAvailableState = 1 << 0;
const int kSendDoneState = 1 << 1;

enum class EspNowEvent {
  NEW_DATA_AVAILABLE,
  // Indicates that the sending has finished. Verify with 'status'
  // that it was successful.
  SEND_DONE,
};

static DatagramPool* datagram_pool;
static esp_now_send_status_t tx_status;
static QueueHandle_t rx_queue;
static QueueHandle_t event_queue;

// This function is registered as callback and will then be called on the high-priority WiFi task.
static void espnow_send_cb(const uint8* mac_addr, esp_now_send_status_t status) {
  tx_status = status;
  auto event = EspNowEvent::SEND_DONE;
  auto ret = xQueueSend(event_queue, &event, 0);
  if (ret != pdTRUE) {
    ESP_LOGE("ESPNow", "Failed to enqueue receive event");
  }
}

// This function is registered as callback and will then be called on the high-priority WiFi task.
static void espnow_recv_cb(const esp_now_recv_info_t* esp_now_info, const uint8* data, int data_len) {
  if (data_len > ESPNOW_RX_DATAGRAM_LEN_MAX) {
    ESP_LOGE("ESPNow", "Receive datagram length=%d is larger than max=%d", data_len, ESPNOW_RX_DATAGRAM_LEN_MAX);
    return ;
  }

  struct Datagram* datagram = datagram_pool->take();
  if (!datagram) {
    ESP_LOGE("ESPNow", "Failed to malloc datagram");
    return;
  }

  datagram->len = data_len;
  memcpy(datagram->mac, esp_now_info->src_addr, 6);
  memcpy(datagram->buffer, data, data_len);

  portBASE_TYPE ret = xQueueSend(rx_queue, &datagram, 0);
  if (ret != pdTRUE) {
    // This should never happen as the rx_queue has the same amount of
    // entries as the pool.
    datagram_pool->release(datagram);
    ESP_LOGE("ESPNow", "Failed to send datagram to rx_queue");
    return;
  }
  auto event = EspNowEvent::NEW_DATA_AVAILABLE;
  ret = xQueueSend(event_queue, &event, 0);
  if (ret != pdTRUE) {
    ESP_LOGE("ESPNow", "Failed to enqueue receive event");
  }
}

class EspNowResourceGroup : public ResourceGroup {
 public:
  TAG(EspNowResourceGroup);

  EspNowResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* r, word data, uint32_t state) {
    auto event = static_cast<EspNowEvent>(data);
    switch (event) {
      case EspNowEvent::NEW_DATA_AVAILABLE:
        state |= kDataAvailableState;
        break;

      case EspNowEvent::SEND_DONE:
        state |= kSendDoneState;
        break;
    };
    return state;
  }
};

class EspNowResource : public EventQueueResource {
 public:
  TAG(EspNowResource);

  EspNowResource(EspNowResourceGroup* group, QueueHandle_t queue)
      : EventQueueResource(group, queue)
      , id_(kInvalidWifiEspnow) {}

  ~EspNowResource() override;

  bool receive_event(word* data) override;

  // Returns null if the initializations succeeded.
  Object* init(Process* process, int mode, Blob pmk, wifi_phy_rate_t phy_rate);

 private:
  enum class State {
    CONSTRUCTED,
    ESPNOW_CLAIMED,
    POOL_ALLOCATED,
    RX_QUEUE_ALLOCATED,
    WIFI_INITTED,
    WIFI_STARTED,
    ESPNOW_INITTED,
    SEND_CALLBACK_REGISTERED,
    RECEIVE_CALLBACK_REGISTERED,
    FULLY_INITIALIZED,
  };
  State state_ = State::CONSTRUCTED;
  int id_;
};

EspNowResource::~EspNowResource() {
  switch (state_) {
    case State::FULLY_INITIALIZED:
    case State::RECEIVE_CALLBACK_REGISTERED:
      esp_now_unregister_recv_cb();
      [[fallthrough]];
    case State::SEND_CALLBACK_REGISTERED:
      esp_now_unregister_send_cb();
      [[fallthrough]];
    case State::ESPNOW_INITTED:
      esp_now_deinit();
      [[fallthrough]];
    case State::WIFI_STARTED:
      esp_wifi_stop();
      [[fallthrough]];
    case State::WIFI_INITTED:
      esp_wifi_deinit();
      [[fallthrough]];
    case State::RX_QUEUE_ALLOCATED:
      vQueueDelete(rx_queue);
      rx_queue = null;
      [[fallthrough]];
    case State::POOL_ALLOCATED:
      delete datagram_pool;
      datagram_pool = NULL;
      [[fallthrough]];
    case State::ESPNOW_CLAIMED:
      wifi_espnow_pool.put(id_);
      [[fallthrough]];
    case State::CONSTRUCTED:
      vQueueDelete(event_queue);
      event_queue = null;
  }
}

Object* EspNowResource::init(Process* process, int mode, Blob pmk, wifi_phy_rate_t phy_rate) {
  id_ = wifi_espnow_pool.any();
  if (id_ == kInvalidWifiEspnow) FAIL(ALREADY_IN_USE);

  state_ = State::ESPNOW_CLAIMED;

  datagram_pool = _new DatagramPool();
  if (datagram_pool == null) {
    FAIL(MALLOC_FAILED);
  }
  state_ = State::POOL_ALLOCATED;

  auto init_result = datagram_pool->init();
  if (init_result != null) {
    return init_result;
  }

  rx_queue = xQueueCreate(ESPNOW_RX_DATAGRAM_NUM, sizeof(Datagram*));
  if (rx_queue == null) {
    FAIL(MALLOC_FAILED);
  }
  state_ = State::RX_QUEUE_ALLOCATED;

  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  wifi_mode_t wifi_mode = mode == 0 ? WIFI_MODE_STA : WIFI_MODE_AP;

  esp_err_t err = esp_wifi_init(&cfg);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  state_ = State::WIFI_INITTED;

  err = esp_wifi_set_storage(WIFI_STORAGE_RAM);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  err = esp_wifi_set_mode(wifi_mode);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = esp_wifi_start();
  if (err != ESP_OK) return Primitive::os_error(err, process);
  state_ = State::WIFI_STARTED;

  wifi_interface_t interface = mode == 0 ? WIFI_IF_STA : WIFI_IF_AP;
  err = esp_wifi_config_espnow_rate(interface, phy_rate);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = esp_now_init();
  if (err != ESP_OK) return Primitive::os_error(err, process);
  state_ = State::ESPNOW_INITTED;

  err = esp_now_register_send_cb(espnow_send_cb);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  state_ = State::SEND_CALLBACK_REGISTERED;

  err = esp_now_register_recv_cb(espnow_recv_cb);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  state_ = State::RECEIVE_CALLBACK_REGISTERED;

  if (pmk.length() > 0) {
    err = esp_now_set_pmk(pmk.address());
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }

  state_ = State::FULLY_INITIALIZED;
  return null;
}

bool EspNowResource::receive_event(word* data) {
  EspNowEvent event;
  bool more = xQueueReceive(queue(), &event, 0);
  if (more) *data = static_cast<uword>(event);
  return more;
}

static wifi_phy_rate_t map_toit_rate_to_esp_idf_rate(int toit_rate) {
  switch (toit_rate) {
    case 0x00: return WIFI_PHY_RATE_1M_L;
    case 0x01: return WIFI_PHY_RATE_2M_L;
    case 0x02: return WIFI_PHY_RATE_5M_L;
    case 0x03: return WIFI_PHY_RATE_11M_L;
    case 0x05: return WIFI_PHY_RATE_2M_S;
    case 0x06: return WIFI_PHY_RATE_5M_S;
    case 0x07: return WIFI_PHY_RATE_11M_S;
    case 0x08: return WIFI_PHY_RATE_48M;
    case 0x09: return WIFI_PHY_RATE_24M;
    case 0x0A: return WIFI_PHY_RATE_12M;
    case 0x0B: return WIFI_PHY_RATE_6M;
    case 0x0C: return WIFI_PHY_RATE_54M;
    case 0x0D: return WIFI_PHY_RATE_36M;
    case 0x0E: return WIFI_PHY_RATE_18M;
    case 0x0F: return WIFI_PHY_RATE_9M;
    case 0x10: return WIFI_PHY_RATE_MCS0_LGI;
    case 0x11: return WIFI_PHY_RATE_MCS1_LGI;
    case 0x12: return WIFI_PHY_RATE_MCS2_LGI;
    case 0x13: return WIFI_PHY_RATE_MCS3_LGI;
    case 0x14: return WIFI_PHY_RATE_MCS4_LGI;
    case 0x15: return WIFI_PHY_RATE_MCS5_LGI;
    case 0x16: return WIFI_PHY_RATE_MCS6_LGI;
    case 0x17: return WIFI_PHY_RATE_MCS7_LGI;
  #if CONFIG_SOC_WIFI_HE_SUPPORT
    case 0x18: return WIFI_PHY_RATE_MCS8_LGI;
    case 0x19: return WIFI_PHY_RATE_MCS9_LGI;
  #endif
    case 0x1A: return WIFI_PHY_RATE_MCS0_SGI;
    case 0x1B: return WIFI_PHY_RATE_MCS1_SGI;
    case 0x1C: return WIFI_PHY_RATE_MCS2_SGI;
    case 0x1D: return WIFI_PHY_RATE_MCS3_SGI;
    case 0x1E: return WIFI_PHY_RATE_MCS4_SGI;
    case 0x1F: return WIFI_PHY_RATE_MCS5_SGI;
    case 0x20: return WIFI_PHY_RATE_MCS6_SGI;
    case 0x21: return WIFI_PHY_RATE_MCS7_SGI;
  #if CONFIG_SOC_WIFI_HE_SUPPORT
    case 0x22: return WIFI_PHY_RATE_MCS8_SGI;
    case 0x23: return WIFI_PHY_RATE_MCS9_SGI;
  #endif
    case 0x29: return WIFI_PHY_RATE_LORA_250K;
    case 0x2A: return WIFI_PHY_RATE_LORA_500K;
    default:
      return static_cast<wifi_phy_rate_t>(-1);
  }
}

MODULE_IMPLEMENTATION(espnow, MODULE_ESPNOW)

PRIMITIVE(init) {
  // Not clear whether we should keep this call to esp_netif_init.
  // The lwip thread is supposed to do this (and normally does so).
  // However, it doesn't seem to be guaranteed.
  // The code looks safe to be executed multiple times, but it's
  // not clear whether it is thread-safe...
  esp_err_t err = esp_netif_init();
  if (err != ESP_OK) return Primitive::os_error(err, process);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new EspNowResourceGroup(process, EventQueueEventSource::instance());
  if (!group) {
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(EspNowResourceGroup, group, int, mode, Blob, pmk, int, rate, int, channel);

  wifi_phy_rate_t phy_rate = WIFI_PHY_RATE_1M_L;
  if (rate != -1) {
    phy_rate =  map_toit_rate_to_esp_idf_rate(rate);
    if (static_cast<int>(phy_rate) == -1) FAIL(INVALID_ARGUMENT);
  }

  if (pmk.length() > 0 && pmk.length() != 16) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  event_queue = xQueueCreate(ESPNOW_EVENT_NUM, sizeof(EspNowEvent));
  if (!event_queue) {
    FAIL(MALLOC_FAILED);
  }

  EspNowResource* resource = _new EspNowResource(group, event_queue);
  if (!resource) {
    vQueueDelete(event_queue);
    FAIL(MALLOC_FAILED);
  }

  // From now on the resource is in charge of all allocations. The
  // event_queue, too, is now deleted by it.

  Object* init_result = resource->init(process, mode, pmk, phy_rate);
  if (init_result != null) {
    delete resource;
    return init_result;
  }

  group->register_resource(resource);
  proxy->set_external_address(resource);

  esp_err_t err = esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return proxy;
}

PRIMITIVE(close) {
  ARGS(EspNowResource, resource);
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(send) {
  ARGS(EspNowResource, resource, Blob, mac, Blob, data);

  esp_err_t err = esp_now_send(mac.address(), data.address(), data.length());
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->null_object();
}

PRIMITIVE(send_succeeded) {
  ARGS(EspNowResource, resource);
  return BOOL(tx_status == ESP_NOW_SEND_SUCCESS);
}

PRIMITIVE(receive) {
  ARGS(EspNowResource, resource);

  struct Datagram* peeked;
  portBASE_TYPE ret = xQueuePeek(rx_queue, &peeked, 0);
  if (ret != pdTRUE) {
    return process->null_object();
  }

  ByteArray* data = process->allocate_byte_array(peeked->len);
  if (data == null) FAIL(ALLOCATION_FAILED);

  ByteArray* mac = process->allocate_byte_array(6);
  if (mac == null) FAIL(ALLOCATION_FAILED);

  Array* result = process->object_heap()->allocate_array(2, process->null_object());
  if (result == null) FAIL(ALLOCATION_FAILED);

  result->at_put(0, mac);
  result->at_put(1, data);

  memcpy(ByteArray::Bytes(mac).address(), peeked->mac, 6);
  memcpy(ByteArray::Bytes(data).address(), peeked->buffer, peeked->len);

  struct Datagram* actual;
  ret = xQueueReceive(rx_queue, &actual, 0);
  if (ret != pdTRUE) {
    // Should not happen: there is only one process owning this resource,
    // and there can't be two tasks executing a primitive call at the same
    // time.
    ESP_LOGE("ESPNow", "Didn't get peeked queue entry");
    return process->null_object();
  }

  datagram_pool->release(actual);

  if (actual != peeked) {
    // As before: this should never happen.
    ESP_LOGE("ESPNow", "Dequeued and peeked entry not the same");
  }

  return result;
}

PRIMITIVE(add_peer) {
  ARGS(EspNowResource, resource, Blob, mac, int, channel, Blob, key);

  wifi_mode_t wifi_mode;
  esp_err_t err = esp_wifi_get_mode(&wifi_mode);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  esp_now_peer_info_t peer;
  memset(&peer, 0, sizeof(esp_now_peer_info_t));
  peer.channel = channel;
  peer.ifidx = wifi_mode == WIFI_MODE_AP ? WIFI_IF_AP : WIFI_IF_STA;
  memcpy(&peer.peer_addr, mac.address(), ESP_NOW_ETH_ALEN);
  if (key.length()) {
    peer.encrypt = true;
    memcpy(peer.lmk, key.address(), ESP_NOW_KEY_LEN);
  } else {
    peer.encrypt = false;
  }
  err = esp_now_add_peer(&peer);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->true_object();
}

} // namespace toit

#endif  // defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_ESPNOW)
