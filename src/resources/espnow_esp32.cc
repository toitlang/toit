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

#if defined(TOIT_ESP32) && \
    (!defined(CONFIG_IDF_TARGET_ESP32P4)) && \
    defined(CONFIG_TOIT_ENABLE_ESPNOW)

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

namespace toit {

class SpinLocker {
 public:
  explicit SpinLocker(spinlock_t* spinlock) : spinlock_(spinlock) { portENTER_CRITICAL(spinlock_); }
  ~SpinLocker() { portEXIT_CRITICAL(spinlock_); }
 private:
  spinlock_t* spinlock_;
};

struct Datagram {
  int offset;
  word len;
  uint8 mac[6];

  bool is_valid() const { return offset >= 0; }
};

class DatagramPool {
 public:
  DatagramPool() {
    spinlock_initialize(&spinlock_);
  }

  ~DatagramPool() {
    delete[] datagrams_;
    free(buffer_);
  }

  Object* init(int buffer_byte_size, int receive_queue_size) {
    buffer_ = unvoid_cast<uint8*>(malloc(buffer_byte_size));
    if (!buffer_) {
      FAIL(MALLOC_FAILED);
    }
    datagrams_ = _new Datagram[receive_queue_size];
    if (!datagrams_) {
      free(buffer_);
      FAIL(MALLOC_FAILED);
    }
    queue_size_ = receive_queue_size;
    buffer_size_ = buffer_byte_size;
    return null;
  }

  bool enqueue(uint8* mac,
               const uint8* data,
               int data_size,
               bool* overflow_queue_size,
               bool* overflow_buffer_size) {
    SpinLocker locker(&spinlock_);
    if (data_size > buffer_size_) return false;

    Datagram* newest = used_ > 0
        ? &datagrams_[(head_ + used_) % queue_size_]
        : null;

    while (true) {
      if (used_ >= queue_size_) {
        *overflow_queue_size = true;
        drop_oldest(locker);
        continue;
      }

      if (used_ > 0) {
        Datagram* oldest = &datagrams_[head_];
        int used_buffer = newest->offset + newest->len - oldest->offset;
        if (used_buffer < 0) used_buffer += buffer_size_;
        int free_buffer = buffer_size_ - used_buffer;
        if (free_buffer < data_size) {
          *overflow_buffer_size = true;
          drop_oldest(locker);
          continue;
        }
      }
      break;
    }

    int index = (head_ + used_) % queue_size_;
    Datagram* datagram = &datagrams_[index];
    int offset = used_ > 0
        ? (newest->offset + newest->len) % buffer_size_
        : 0;
    datagram->offset = offset;
    datagram->len = data_size;
    // Copy in two steps to handle wrap-around.
    int first_copy = Utils::min(data_size, buffer_size_ - offset);
    memcpy(buffer_ + offset, data, first_copy);
    int second_copy = data_size - first_copy;
    if (second_copy > 0) {
      memcpy(buffer_, data + first_copy, second_copy);
    }
    memcpy(datagram->mac, mac, 6);
    used_++;
    return true;
  }

  /// If the given datagram is still the oldest one, copy its data into the
  /// out_buffer and remove it from the queue.
  /// Returns true if the datagram was valid and copied. False, otherwise.
  bool consume(const Datagram& datagram, uint8* out_buffer) {
    SpinLocker locker(&spinlock_);
    if (used_ == 0) return false;  // Should never happen.
    Datagram* oldest = &datagrams_[head_];
    if (memcmp(&datagram, oldest, sizeof(Datagram)) != 0) {
      // The oldest datagram is not the same anymore.
      return false;
    }
    // Copy in two steps to handle wrap-around.
    int first_copy = Utils::min(datagram.len, buffer_size_ - datagram.offset);
    memcpy(out_buffer, buffer_ + datagram.offset, first_copy);
    int second_copy = datagram.len - first_copy;
    if (second_copy > 0) {
      memcpy(out_buffer + first_copy, buffer_, second_copy);
    }
    drop_oldest(locker);
    return true;
  }

  Datagram peek() {
    SpinLocker locker(&spinlock_);
    if (used_ == 0) {
      return {
        .offset = -1,
        .len = 0,
        .mac = {0},
      };
    }
    return datagrams_[head_];
  }

 private:
  spinlock_t spinlock_{};
  uint8* buffer_ = null;
  int buffer_size_ = 0;
  struct Datagram* datagrams_ = null;
  int head_ = 0;
  int used_ = 0;
  int queue_size_ = 0;

  void drop_oldest(const SpinLocker& locker) {
    ASSERT(used_ > 0);
    head_ = (head_ + 1) % queue_size_;
    used_--;
  }
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
// Only one message can be sent at a time, so we only need one status variable.
static esp_now_send_status_t tx_status;
// The size of the event queue.
// We rely on the fact that sending is blocking until it has been sent.
// This means that there is at most one pending send-done event in the queue.
// If only one event is in the queue, then we might add a receive event (independently,
// of whether there is already one in the queue or not). If there are two events in
// the queue, we will never add a receive event, as there is already one in the queue.
const int kEventQueueSize = 3;
static QueueHandle_t event_queue;

// This function is registered as callback and will then be called on the high-priority WiFi task.
static void espnow_send_cb(const uint8* mac_addr, esp_now_send_status_t status) {
  tx_status = status;
  auto event = EspNowEvent::SEND_DONE;
  auto ret = xQueueSend(event_queue, &event, 0);
  if (ret != pdTRUE) {
    // This should never happen as the event_queue has always space for one send-done.
    ESP_LOGE("ESPNow", "Failed to enqueue send-done event");
  }
}

// This function is registered as callback and will then be called on the high-priority WiFi task.
static void espnow_recv_cb(const esp_now_recv_info_t* esp_now_info, const uint8* data, int data_len) {
  bool overflow_queue_size = false;
  bool overflow_buffer_size = false;
  bool success = datagram_pool->enqueue(esp_now_info->src_addr,
                                        data,
                                        data_len,
                                        &overflow_queue_size,
                                        &overflow_buffer_size);
  if (!success) {
    ESP_LOGE("ESPNow", "Received datagram length=%d, larger than buffer", data_len);
    return;
  }
  if (overflow_queue_size) {
    ESP_LOGE("ESPNow", "Dropped datagram due to queue size");
  }
  if (overflow_buffer_size) {
    ESP_LOGE("ESPNow", "Dropped datagram due to buffer size");
  }

  // Always keep at least one slot for a "send-done" event in the queue.
  // We just need *one* event in the queue for receive events. Since the
  // queue is bigger than 2 elements, and there is never more than one
  // send-done event, we just need to check that there is more than one
  // slot left.
  static_assert(kEventQueueSize >= 3, "Unexpected event queue size");
  if (uxQueueSpacesAvailable(event_queue) > 1) {
    auto event = EspNowEvent::NEW_DATA_AVAILABLE;
    portBASE_TYPE ret = xQueueSend(event_queue, &event, 0);
    if (ret != pdTRUE) {
      ESP_LOGE("ESPNow", "Failed to enqueue receive event");
    }
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
  Object* init(Process* process, Blob pmk, int buffer_byte_size, int receive_queue_size);

 private:
  enum class State {
    CONSTRUCTED,
    ESPNOW_CLAIMED,
    POOL_ALLOCATED,
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

Object* EspNowResource::init(Process* process,
                             Blob pmk,
                             int buffer_byte_size,
                             int receive_queue_size) {
  id_ = wifi_espnow_pool.any();
  if (id_ == kInvalidWifiEspnow) FAIL(ALREADY_IN_USE);

  state_ = State::ESPNOW_CLAIMED;

  datagram_pool = _new DatagramPool();
  if (datagram_pool == null) {
    FAIL(MALLOC_FAILED);
  }
  state_ = State::POOL_ALLOCATED;

  auto init_result = datagram_pool->init(buffer_byte_size, receive_queue_size);
  if (init_result != null) {
    return init_result;
  }

  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  esp_err_t err = esp_wifi_init(&cfg);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  state_ = State::WIFI_INITTED;

  err = esp_wifi_set_storage(WIFI_STORAGE_RAM);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = esp_wifi_set_mode(WIFI_MODE_STA);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = esp_wifi_start();
  if (err != ESP_OK) return Primitive::os_error(err, process);
  state_ = State::WIFI_STARTED;

  uint8 protocol;
  err = esp_wifi_get_protocol(WIFI_IF_STA, &protocol);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  protocol |= WIFI_PROTOCOL_LR;

  err = esp_wifi_set_protocol(WIFI_IF_STA, protocol);
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

static wifi_phy_mode_t map_toit_mode_to_esp_idf_mode(int toit_mode) {
  switch (toit_mode) {
    case 0: return WIFI_PHY_MODE_LR;
    case 1: return WIFI_PHY_MODE_11B;
    case 2: return WIFI_PHY_MODE_11G;
    case 3: return WIFI_PHY_MODE_11A;
    case 4: return WIFI_PHY_MODE_HT20;
    case 5: return WIFI_PHY_MODE_HT40;
    case 6: return WIFI_PHY_MODE_HE20;
    case 7: return WIFI_PHY_MODE_VHT20;
    default:
      return static_cast<wifi_phy_mode_t>(-1);
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
  ARGS(EspNowResourceGroup, group, Blob, pmk, int, channel, int, buffer_byte_size, int, receive_queue_size);

  if (pmk.length() > 0 && pmk.length() != 16) FAIL(INVALID_ARGUMENT);
  if (buffer_byte_size < 1) FAIL(INVALID_ARGUMENT);
  if (receive_queue_size < 1) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  event_queue = xQueueCreate(kEventQueueSize, sizeof(EspNowEvent));
  if (!event_queue) {
    FAIL(MALLOC_FAILED);
  }

  EspNowResource* resource =
      _new EspNowResource(group, event_queue);
  if (!resource) {
    vQueueDelete(event_queue);
    FAIL(MALLOC_FAILED);
  }

  // From now on the resource is in charge of all allocations. The
  // event_queue, too, is now deleted by it.

  Object* init_result = resource->init(process, pmk, buffer_byte_size, receive_queue_size);
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

  Datagram peeked = datagram_pool->peek();
  if (!peeked.is_valid()) return process->null_object();

  ByteArray* mac = process->allocate_byte_array(6);
  if (mac == null) FAIL(ALLOCATION_FAILED);

  Array* result = process->object_heap()->allocate_array(2, process->null_object());
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray* data = null;
  while (true) {
    if (data == null || data->size() != peeked.len) {
      data = process->allocate_byte_array(peeked.len);
      if (data == null) FAIL(ALLOCATION_FAILED);
    }

    bool success = datagram_pool->consume(peeked, ByteArray::Bytes(data).address());
    if (success) {
      memcpy(ByteArray::Bytes(mac).address(), peeked.mac, 6);

      result->at_put(0, mac);
      result->at_put(1, data);

      return result;
    }

    // The oldest datagram was discarded to make space for a new one.
    peeked = datagram_pool->peek();
    if (!peeked.is_valid()) FATAL("Expected valid datagram");
  }
}

PRIMITIVE(add_peer) {
  ARGS(EspNowResource, resource, Blob, mac, int, channel, Blob, key, int, mode, int, rate);

  if ((mode != -1 && rate == -1) || (mode == -1 && rate != -1)) FAIL(INVALID_ARGUMENT);

  wifi_phy_mode_t phy_mode = WIFI_PHY_MODE_LR;
  wifi_phy_rate_t phy_rate = WIFI_PHY_RATE_1M_L;
  if (mode != -1) {
    phy_rate =  map_toit_rate_to_esp_idf_rate(rate);
    if (static_cast<int>(phy_rate) == -1) FAIL(INVALID_ARGUMENT);

    phy_mode = map_toit_mode_to_esp_idf_mode(mode);
    if (static_cast<int>(phy_mode) == -1) FAIL(INVALID_ARGUMENT);
  }

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

  if (mode != -1) {
    esp_now_rate_config_t rate_config {
      .phymode = phy_mode,
      .rate = phy_rate,
      .ersu = false,
      .dcm = false,
    };
    esp_wifi_set_protocol(WIFI_IF_STA, WIFI_PROTOCOL_LR);
    err = esp_now_set_peer_rate_config(peer.peer_addr, &rate_config);
    if (err != ESP_OK) {
      esp_now_del_peer(peer.peer_addr);
      return Primitive::os_error(err, process);
    }
  }

  return process->null_object();
}

PRIMITIVE(remove_peer) {
  ARGS(EspNowResource, resource, Blob, mac);

  esp_err_t err = esp_now_del_peer(mac.address());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

} // namespace toit

#endif  // defined(TOIT_ESP32) && !defined(CONFIG_IDF_TARGET_ESP32P4) && defined(CONFIG_TOIT_ENABLE_ESPNOW)
