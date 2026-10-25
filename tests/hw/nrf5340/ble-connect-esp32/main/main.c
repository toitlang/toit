// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.

// Independent connection-lifecycle peer using Bluedroid rather than NimBLE.
// It deliberately has no Toit VM or application GATT database. The unchanged
// nRF connection test needs only connectable advertising and GAP events.
#include <assert.h>
#include <stdio.h>

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "nvs_flash.h"

static unsigned connections;
static unsigned disconnections;
static unsigned advertisements;

static uint8_t advertisement[] = {
    2, ESP_BLE_AD_TYPE_FLAG, ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT,
    14, ESP_BLE_AD_TYPE_NAME_CMPL,
    't', 'o', 'i', 't', '-', 'e', 's', 'p', '-', 'p', 'e', 'e', 'r',
};

static esp_ble_adv_params_t parameters = {
    .adv_int_min = 0x20,
    .adv_int_max = 0x40,
    .adv_type = ADV_TYPE_IND,
    .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
    .channel_map = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

static void advertise(void) {
  ESP_ERROR_CHECK(esp_ble_gap_start_advertising(&parameters));
}

static void gap_event(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t* param) {
  switch (event) {
    case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
      assert(param->adv_data_raw_cmpl.status == ESP_BT_STATUS_SUCCESS);
      advertise();
      break;
    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
      assert(param->adv_start_cmpl.status == ESP_BT_STATUS_SUCCESS);
      ++advertisements;
      printf("ESP32 BLUEDROID READY advertisements=%u connections=%u disconnections=%u\n",
             advertisements, connections, disconnections);
      break;
    default:
      break;
  }
}

static void gatt_event(esp_gatts_cb_event_t event, esp_gatt_if_t interface,
                       esp_ble_gatts_cb_param_t* param) {
  (void)interface;
  switch (event) {
    case ESP_GATTS_REG_EVT:
      assert(param->reg.status == ESP_GATT_OK);
      ESP_ERROR_CHECK(esp_ble_gap_config_adv_data_raw(advertisement, sizeof(advertisement)));
      break;
    case ESP_GATTS_CONNECT_EVT:
      assert(connections == disconnections);
      ++connections;
      printf("ESP32 BLUEDROID CONNECT count=%u handle=%u\n", connections, param->connect.conn_id);
      break;
    case ESP_GATTS_DISCONNECT_EVT:
      assert(connections == disconnections + 1);
      ++disconnections;
      printf("ESP32 BLUEDROID DISCONNECT count=%u reason=0x%02x\n",
             disconnections, param->disconnect.reason);
      // Restart on the actual disconnect event, with no polling or sleep.
      advertise();
      break;
    default:
      break;
  }
}

void app_main(void) {
  esp_err_t result = nvs_flash_init();
  if (result == ESP_ERR_NVS_NO_FREE_PAGES || result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    result = nvs_flash_init();
  }
  ESP_ERROR_CHECK(result);
  ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));
  esp_bt_controller_config_t config = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(esp_bt_controller_init(&config));
  ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
  ESP_ERROR_CHECK(esp_bluedroid_init());
  ESP_ERROR_CHECK(esp_bluedroid_enable());
  ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_event));
  ESP_ERROR_CHECK(esp_ble_gatts_register_callback(gatt_event));
  ESP_ERROR_CHECK(esp_ble_gatts_app_register(0));
}
