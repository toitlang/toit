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

#if defined(TOIT_FREERTOS) && defined(CONFIG_TOIT_ENABLE_ESPNOW)

#include <esp_wifi.h>
#include <esp_event.h>
#include <esp_netif.h>
#include <esp_now.h>
#include <esp_log.h>

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/system_esp32.h"
#include "../event_sources/ev_queue_esp32.h"

#define ESPNOW_RX_DATAGRAM_NUM      8
#define ESPNOW_RX_DATAGRAM_LEN_MAX  250
#define ESPNOW_TX_WAIT_US           1000
// The size of the event queue.
#define ESPNOW_EVENT_NUM            16

namespace toit {

struct DataGram {
  bool used;
  int len;
  uint8_t mac[6];
  uint8_t buffer[ESPNOW_RX_DATAGRAM_LEN_MAX];
};

const int kInvalidEspNow = -1;

// These constants must be synchronized with the Toit code.
const int kDataAvailableState = 1 << 0;
const int kSendDoneState = 1 << 1;

enum class EspNowEvent {
  NEW_DATA_AVAILABLE,
  // Indicates that the sending has finished. Verify with 'status'
  // that it was successful.
  SEND_DONE,
};

// Only allow one instance to use espnow.
static  ResourcePool<int, kInvalidEspNow> espnow_pool(
  0
);

static esp_now_send_status_t tx_status;
static QueueHandle_t rx_queue;
static SemaphoreHandle_t rx_datagrams_mutex;
static struct DataGram* rx_datagrams;
static QueueHandle_t event_queue;

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

  EspNowResource(EspNowResourceGroup* group, int id, QueueHandle_t queue)
      : EventQueueResource(group, queue)
      , id_(id) {}

  ~EspNowResource() override;

  bool receive_event(word* data) override;

 private:
  int id_;
};

EspNowResource::~EspNowResource() {
  vQueueDelete(rx_queue);
  rx_queue = NULL;

  vSemaphoreDelete(rx_datagrams_mutex);
  rx_datagrams_mutex = NULL;

  free(rx_datagrams);
  rx_datagrams = NULL;

  esp_now_deinit();
  espnow_pool.put(id_);
  esp_wifi_stop();
}

static bool init() {
  rx_queue = xQueueCreate(ESPNOW_RX_DATAGRAM_NUM, sizeof(void*));
  if (!rx_queue) {
    return false;
  }

  rx_datagrams_mutex = xSemaphoreCreateMutex();
  if (!rx_datagrams_mutex) {
    vQueueDelete(rx_queue);
    rx_queue = NULL;
    return false;
  }

  rx_datagrams = unvoid_cast<struct DataGram*>(malloc(sizeof(struct DataGram) * ESPNOW_RX_DATAGRAM_NUM));
  if (!rx_datagrams) {
    vSemaphoreDelete(rx_datagrams_mutex);
    rx_datagrams_mutex = NULL;
    vQueueDelete(rx_queue);
    rx_queue = NULL;
    return false;
  }

  event_queue = xQueueCreate(ESPNOW_EVENT_NUM, sizeof(EspNowEvent));
  if (!event_queue) {
    free(rx_datagrams);
    rx_datagrams = NULL;
    vSemaphoreDelete(rx_datagrams_mutex);
    rx_datagrams_mutex = NULL;
    vQueueDelete(rx_queue);
    rx_queue = NULL;
    return false;
  }

  return true;
}

bool EspNowResource::receive_event(word* data) {
  EspNowEvent event;
  bool more = xQueueReceive(queue(), &event, 0);
  if (more) *data = static_cast<uword>(event);
  return more;
}

static struct DataGram* alloc_datagram(void) {
  struct DataGram *datagram = NULL;

  xSemaphoreTake(rx_datagrams_mutex, portMAX_DELAY);
  for (int i = 0; i < ESPNOW_RX_DATAGRAM_NUM; i++) {
    if (!rx_datagrams[i].used) {
      datagram = &rx_datagrams[i];
      datagram->used = true;
      break;
    }
  }
  xSemaphoreGive(rx_datagrams_mutex);

  return datagram;
}

static void free_datagram(struct DataGram* datagram) {
  xSemaphoreTake(rx_datagrams_mutex, portMAX_DELAY);
  datagram->used = false;
  xSemaphoreGive(rx_datagrams_mutex);
}

static void espnow_send_cb(const uint8_t *mac_addr, esp_now_send_status_t status) {
  tx_status = status;
  auto event = EspNowEvent::SEND_DONE;
  auto ret = xQueueSend(event_queue, &event, 0);
  if (ret != pdTRUE) {
    ESP_LOGE("ESPNow", "Failed to enqueue receive event");
  }
}

static void espnow_recv_cb(const uint8_t *mac_addr, const uint8_t *data, int data_len) {
  if (data_len > ESPNOW_RX_DATAGRAM_LEN_MAX) {
    ESP_LOGE("ESPNow", "Receive datagram length=%d is larger than max=%d", data_len, ESPNOW_RX_DATAGRAM_LEN_MAX);
    return ;
  }

  struct DataGram* datagram = alloc_datagram();
  if (!datagram) {
    ESP_LOGE("ESPNow", "Failed to malloc datagram");
    return;
  }

  datagram->len = data_len;
  memcpy(datagram->mac, mac_addr, 6);
  memcpy(datagram->buffer, data, data_len);

  portBASE_TYPE ret = xQueueSend(rx_queue, &datagram, 0);
  if (ret != pdTRUE) {
    free_datagram(datagram);
    ESP_LOGE("ESPNow", "Failed to send datagram to rx_queue");
    return;
  }
  auto event = EspNowEvent::NEW_DATA_AVAILABLE;
  ret = xQueueSend(event_queue, &event, 0);
  if (ret != pdTRUE) {
    ESP_LOGE("ESPNow", "Failed to enqueue receive event");
  }
}

static wifi_phy_rate_t map_toit_rate_to_esp_idf_rate(int toit_rate) {
  static_assert(WIFI_PHY_RATE_1M_L == 0x00, "WIFI_PHY_RATE_1M_L must be 0x00");
  static_assert(WIFI_PHY_RATE_2M_L == 0x01, "WIFI_PHY_RATE_2M_L must be 0x01");
  static_assert(WIFI_PHY_RATE_5M_L == 0x02, "WIFI_PHY_RATE_5M_L must be 0x02");
  static_assert(WIFI_PHY_RATE_11M_L == 0x03, "WIFI_PHY_RATE_11M_L must be 0x03");
  static_assert(WIFI_PHY_RATE_2M_S == 0x05, "WIFI_PHY_RATE_2M_S must be 0x05");
  static_assert(WIFI_PHY_RATE_5M_S == 0x06, "WIFI_PHY_RATE_5M_S must be 0x06");
  static_assert(WIFI_PHY_RATE_11M_S == 0x07, "WIFI_PHY_RATE_11M_S must be 0x07");
  static_assert(WIFI_PHY_RATE_48M == 0x08, "WIFI_PHY_RATE_48M must be 0x08");
  static_assert(WIFI_PHY_RATE_24M == 0x09, "WIFI_PHY_RATE_24M must be 0x09");
  static_assert(WIFI_PHY_RATE_12M == 0x0A, "WIFI_PHY_RATE_12M must be 0x0A");
  static_assert(WIFI_PHY_RATE_6M == 0x0B, "WIFI_PHY_RATE_6M must be 0x0B");
  static_assert(WIFI_PHY_RATE_54M == 0x0C, "WIFI_PHY_RATE_54M must be 0x0C");
  static_assert(WIFI_PHY_RATE_36M == 0x0D, "WIFI_PHY_RATE_36M must be 0x0D");
  static_assert(WIFI_PHY_RATE_18M == 0x0E, "WIFI_PHY_RATE_18M must be 0x0E");
  static_assert(WIFI_PHY_RATE_9M == 0x0F, "WIFI_PHY_RATE_9M must be 0x0F");
  static_assert(WIFI_PHY_RATE_MCS0_LGI == 0x10, "WIFI_PHY_RATE_MCS0_LGI must be 0x10");
  static_assert(WIFI_PHY_RATE_MCS1_LGI == 0x11, "WIFI_PHY_RATE_MCS1_LGI must be 0x11");
  static_assert(WIFI_PHY_RATE_MCS2_LGI == 0x12, "WIFI_PHY_RATE_MCS2_LGI must be 0x12");
  static_assert(WIFI_PHY_RATE_MCS3_LGI == 0x13, "WIFI_PHY_RATE_MCS3_LGI must be 0x13");
  static_assert(WIFI_PHY_RATE_MCS4_LGI == 0x14, "WIFI_PHY_RATE_MCS4_LGI must be 0x14");
  static_assert(WIFI_PHY_RATE_MCS5_LGI == 0x15, "WIFI_PHY_RATE_MCS5_LGI must be 0x15");
  static_assert(WIFI_PHY_RATE_MCS6_LGI == 0x16, "WIFI_PHY_RATE_MCS6_LGI must be 0x16");
  static_assert(WIFI_PHY_RATE_MCS7_LGI == 0x17, "WIFI_PHY_RATE_MCS7_LGI must be 0x17");
  static_assert(WIFI_PHY_RATE_MCS0_SGI == 0x18, "WIFI_PHY_RATE_MCS0_SGI must be 0x18");
  static_assert(WIFI_PHY_RATE_MCS1_SGI == 0x19, "WIFI_PHY_RATE_MCS1_SGI must be 0x19");
  static_assert(WIFI_PHY_RATE_MCS2_SGI == 0x1A, "WIFI_PHY_RATE_MCS2_SGI must be 0x1A");
  static_assert(WIFI_PHY_RATE_MCS3_SGI == 0x1B, "WIFI_PHY_RATE_MCS3_SGI must be 0x1B");
  static_assert(WIFI_PHY_RATE_MCS4_SGI == 0x1C, "WIFI_PHY_RATE_MCS4_SGI must be 0x1C");
  static_assert(WIFI_PHY_RATE_MCS5_SGI == 0x1D, "WIFI_PHY_RATE_MCS5_SGI must be 0x1D");
  static_assert(WIFI_PHY_RATE_MCS6_SGI == 0x1E, "WIFI_PHY_RATE_MCS6_SGI must be 0x1E");
  static_assert(WIFI_PHY_RATE_MCS7_SGI == 0x1F, "WIFI_PHY_RATE_MCS7_SGI must be 0x1F");
  static_assert(WIFI_PHY_RATE_LORA_250K == 0x29, "WIFI_PHY_RATE_LORA_250K must be 0x29");
  static_assert(WIFI_PHY_RATE_LORA_500K == 0x2A, "WIFI_PHY_RATE_LORA_500K must be 0x2A");
  if ((0x00 <= toit_rate && toit_rate <= 0x1F) ||
      (0x29 <= toit_rate && toit_rate <= 0x2A)) {
    return static_cast<wifi_phy_rate_t>(toit_rate);
  }
  return static_cast<wifi_phy_rate_t>(-1);
}

MODULE_IMPLEMENTATION(espnow, MODULE_ESPNOW)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    FAIL(ALLOCATION_FAILED);
  }

  auto group = _new EspNowResourceGroup(process, EventQueueEventSource::instance());
  if (!group) {
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(EspNowResourceGroup, group, int, mode, Blob, pmk, int, rate);

  wifi_phy_rate_t phy_rate = WIFI_PHY_RATE_1M_L;
  if (rate != -1) {
    phy_rate =  map_toit_rate_to_esp_idf_rate(rate);
    if (static_cast<int>(phy_rate) == -1) FAIL(INVALID_ARGUMENT);
  }

  if (pmk.length() > 0 && pmk.length() != 16) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    FAIL(ALLOCATION_FAILED);
  }

  int id = espnow_pool.any();
  if (id == kInvalidEspNow) FAIL(ALREADY_IN_USE);

  if (!init()) {
    espnow_pool.put(id);
    FAIL(MALLOC_FAILED);
  }

  EspNowResource* resource = _new EspNowResource(group, id, event_queue);
  if (!resource) {
    espnow_pool.put(id);
    FAIL(MALLOC_FAILED);
  }

  // TODO(florian): we are leaking the resource and
  // all the allocated entries (from 'init') if one of the
  // following calls fails.


  // Not clear whether we should keep this call to esp_netif_init.
  // The lwip thread is supposed to do this (and normally does so).
  // However, it doesn't seem to be guaranteed.
  // The code looks safe to be executed multiple times, but it's
  // not clear whether it is thread-safe...
  esp_err_t err = esp_netif_init();
  if (err != ESP_OK) return Primitive::os_error(err, process);
  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  wifi_mode_t wifi_mode = mode == 0 ? WIFI_MODE_STA : WIFI_MODE_AP;

  err = esp_wifi_init(&cfg);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  err = esp_wifi_set_storage(WIFI_STORAGE_RAM);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  err = esp_wifi_set_mode(wifi_mode);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  err = esp_wifi_start();
  if (err != ESP_OK) return Primitive::os_error(err, process);

  wifi_interface_t interface = mode == 0 ? WIFI_IF_STA : WIFI_IF_AP;
  err = esp_wifi_config_espnow_rate(interface, phy_rate);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = esp_now_init();
  if (err != ESP_OK) return Primitive::os_error(err, process);
  err = esp_now_register_send_cb(espnow_send_cb);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  err = esp_now_register_recv_cb(espnow_recv_cb);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  if (pmk.length() > 0) {
    err = esp_now_set_pmk(pmk.address());
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }

  group->register_resource(resource);
  proxy->set_external_address(resource);

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
  ARGS(EspNowResource, resource, Object, output);

  Array* out = Array::cast(output);
  if (out->length() != 2) FAIL(INVALID_ARGUMENT);

  ByteArray* mac = null;
  mac = process->allocate_byte_array(6);
  if (mac == null) FAIL(ALLOCATION_FAILED);

  ByteArray* data = process->allocate_byte_array(ESPNOW_RX_DATAGRAM_LEN_MAX, true);
  if (data == null) FAIL(ALLOCATION_FAILED);

  struct DataGram* datagram;
  portBASE_TYPE ret = xQueueReceive(rx_queue, &datagram, 0);
  if (ret != pdTRUE) {
    return process->null_object();
  }

  data->resize_external(process, datagram->len);

  memcpy(ByteArray::Bytes(mac).address(), datagram->mac, 6);
  memcpy(ByteArray::Bytes(data).address(), datagram->buffer, datagram->len);
  free_datagram(datagram);

  out->at_put(0, mac);
  out->at_put(1, data);

  return out;
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

#endif
