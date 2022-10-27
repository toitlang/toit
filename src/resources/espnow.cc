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

#define ESPNOW_RX_DATAGRAM_NUM      8
#define ESPNOW_RX_DATAGRAM_LEN_MAX  250
#define ESPNOW_TX_WAIT_US           1000

namespace toit {

struct DataGram {
  bool used;
  int len;
  uint8_t mac[6];
  uint8_t buffer[ESPNOW_RX_DATAGRAM_LEN_MAX];
};

const int kInvalidESPNow = -1;

// Only allow one instance of provisioning running.
static  ResourcePool<int, kInvalidESPNow> espnow_pool(
  0
);

static SemaphoreHandle_t tx_sem;
static esp_now_send_status_t tx_status;
static QueueHandle_t rx_queue;
static SemaphoreHandle_t rx_datagrams_mutex;
static struct DataGram* rx_datagrams;

class ESPNowResourceGroup : public ResourceGroup {
 public:
  TAG(ESPNowResourceGroup);

  ESPNowResourceGroup(Process* process);
  ~ESPNowResourceGroup();
};

ESPNowResourceGroup::ESPNowResourceGroup(Process* process)
  : ResourceGroup(process) {
  tx_sem = xSemaphoreCreateCounting(1, 0);
  ASSERT(tx_sem);

  rx_queue = xQueueCreate(ESPNOW_RX_DATAGRAM_NUM, sizeof(void *));
  ASSERT(rx_queue);

  rx_datagrams_mutex = xSemaphoreCreateMutex();
  ASSERT(rx_datagrams_mutex);

  rx_datagrams = unvoid_cast<struct DataGram*>(malloc(sizeof(struct DataGram) * ESPNOW_RX_DATAGRAM_NUM));
  ASSERT(rx_datagrams);
}

ESPNowResourceGroup::~ESPNowResourceGroup() {
  vSemaphoreDelete(tx_sem);
  tx_sem = NULL;

  vQueueDelete(rx_queue);
  rx_queue = NULL;

  vSemaphoreDelete(rx_datagrams_mutex);
  rx_datagrams_mutex = NULL;

  free(rx_datagrams);
  rx_datagrams = NULL;
}

MODULE_IMPLEMENTATION(espnow, MODULE_ESPNOW)

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
  portBASE_TYPE ret = xSemaphoreGive(tx_sem);
  if (ret != pdTRUE) {
    // ESP_LOGE("ESPNow", "Failed to give TX semaphore");
    return ;
  }
}

static void espnow_recv_cb(const uint8_t *mac_addr, const uint8_t *data, int data_len) {
  if (data_len > ESPNOW_RX_DATAGRAM_LEN_MAX) {
    ESP_LOGE("ESPNow", "Receive datagram length=%d is larger than max=%d", data_len, ESPNOW_RX_DATAGRAM_LEN_MAX);
    return ;
  }

  struct DataGram* datagram = alloc_datagram();
  if (!datagram) {
    // ESP_LOGE("ESPNow", "Failed to malloc datagram");
    return ;
  }

  datagram->len = data_len;
  memcpy(datagram->mac, mac_addr, 6);
  memcpy(datagram->buffer, data, data_len);

  portBASE_TYPE ret = xQueueSend(rx_queue, &datagram, 0);
  if (ret != pdTRUE) {
    free_datagram(datagram);
    // ESP_LOGE("ESPNow", "Failed to send datagram to rx_queue");
  }
}

PRIMITIVE(init) {
  ARGS(int, mode, Blob, pmk);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  int id = espnow_pool.any();
  if (id == kInvalidESPNow) ALREADY_IN_USE;

  ESPNowResourceGroup* group = _new ESPNowResourceGroup(process);
  if (!group) {
    espnow_pool.put(id);
    MALLOC_FAILED;
  }

  FATAL_IF_NOT_ESP_OK(esp_netif_init());
  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  wifi_mode_t wifi_mode = mode ? WIFI_MODE_AP : WIFI_MODE_STA;

  FATAL_IF_NOT_ESP_OK(esp_wifi_init(&cfg));
  FATAL_IF_NOT_ESP_OK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
  FATAL_IF_NOT_ESP_OK(esp_wifi_set_mode(wifi_mode));
  FATAL_IF_NOT_ESP_OK(esp_wifi_start());

  FATAL_IF_NOT_ESP_OK(esp_now_init());
  FATAL_IF_NOT_ESP_OK(esp_now_register_send_cb(espnow_send_cb));
  FATAL_IF_NOT_ESP_OK(esp_now_register_recv_cb(espnow_recv_cb));
  if (pmk.length() > 0) {
    FATAL_IF_NOT_ESP_OK(esp_now_set_pmk(pmk.address()));
  }

  proxy->set_external_address(group);

  return proxy;
}

PRIMITIVE(send) {
  ARGS(Blob, mac, Blob, data, bool, wait);

  // Reset the value of semaphore(max value is 1) to 0, so don't need to check result
  xSemaphoreTake(tx_sem, 0);

  FATAL_IF_NOT_ESP_OK(esp_now_send(mac.address(), data.address(), data.length()));

  if (wait) {
    portBASE_TYPE ret = xSemaphoreTake(tx_sem, pdMS_TO_TICKS(ESPNOW_TX_WAIT_US));
    if (ret != pdTRUE) {
      return Primitive::os_error(ETIMEDOUT, process);
    } else {
      if (tx_status != ESP_NOW_SEND_SUCCESS) {
        return Primitive::os_error(EIO, process);
      }
    }
  }

  return Smi::from(0);
}

PRIMITIVE(receive) {
  ARGS(Object, output);

  Array* out = Array::cast(output);
  if (out->length() != 2) INVALID_ARGUMENT;

  ByteArray* mac = null;
  mac = process->allocate_byte_array(6);
  if (mac == null) ALLOCATION_FAILED;

  ByteArray* data = process->allocate_byte_array(ESPNOW_RX_DATAGRAM_LEN_MAX, true);
  if (data == null) ALLOCATION_FAILED;

  struct DataGram* datagram;
  portBASE_TYPE ret = xQueueReceive(rx_queue, &datagram, 0);
  if (ret != pdTRUE) {
    return process->program()->null_object();
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
  ARGS(Blob, mac, int, channel, Blob, key);

  wifi_mode_t wifi_mode;
  FATAL_IF_NOT_ESP_OK(esp_wifi_get_mode(&wifi_mode));

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
  FATAL_IF_NOT_ESP_OK(esp_now_add_peer(&peer));

  return process->program()->true_object(); 
}

PRIMITIVE(deinit) {
  ARGS(ESPNowResourceGroup, group);

  FATAL_IF_NOT_ESP_OK(esp_now_deinit());

  group->tear_down();
  group_proxy->clear_external_address();

  return process->program()->null_object();
}

} // namespace toit

#endif
