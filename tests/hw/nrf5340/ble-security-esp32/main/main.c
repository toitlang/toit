// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
// Independent Bluedroid peer. Never print private keys or key-event payloads.
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "driver/uart.h"
#include "driver/uart_vfs.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"

enum { ACCEPT, REJECT, NO_BOND, LEGACY, HOLD };
static atomic_int mode;
static atomic_uint connections, disconnections, authentications, key_events;
static uint8_t advertisement[] = {
  2, ESP_BLE_AD_TYPE_FLAG, ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT,
  14, ESP_BLE_AD_TYPE_NAME_CMPL,
  't','o','i','t','-','s','e','c','-','p','e','e','r',
};
static esp_ble_adv_params_t parameters = {
  .adv_int_min = 0x20, .adv_int_max = 0x40, .adv_type = ADV_TYPE_IND,
  .own_addr_type = BLE_ADDR_TYPE_PUBLIC, .channel_map = ADV_CHNL_ALL,
  .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};
static uint16_t primary_uuid = ESP_GATT_UUID_PRI_SERVICE;
static uint16_t declaration_uuid = ESP_GATT_UUID_CHAR_DECLARE;
static uint16_t service_uuid = 0xfff0, value_uuid = 0xfff1;
static uint8_t properties = ESP_GATT_CHAR_PROP_BIT_READ;
static uint8_t value[] = "toit-secure-v1";
static const esp_gatts_attr_db_t attributes[] = {
  {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t *)&primary_uuid, ESP_GATT_PERM_READ,
                        sizeof(service_uuid), sizeof(service_uuid), (uint8_t *)&service_uuid}},
  {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t *)&declaration_uuid, ESP_GATT_PERM_READ,
                        sizeof(properties), sizeof(properties), &properties}},
  {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t *)&value_uuid, ESP_GATT_PERM_READ_ENCRYPTED,
                        sizeof(value) - 1, sizeof(value) - 1, value}},
};

static void configure_security(int policy) {
  esp_ble_auth_req_t auth = policy == LEGACY ? ESP_LE_AUTH_BOND
      : policy == NO_BOND ? ESP_LE_AUTH_REQ_SC_ONLY : ESP_LE_AUTH_REQ_SC_BOND;
  uint8_t io = ESP_IO_CAP_NONE, size = 16;
  uint8_t keys = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
  uint8_t strict = ESP_BLE_ONLY_ACCEPT_SPECIFIED_AUTH_ENABLE;
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_AUTHEN_REQ_MODE, &auth, sizeof(auth)));
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_IOCAP_MODE, &io, sizeof(io)));
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_MAX_KEY_SIZE, &size, sizeof(size)));
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_SET_INIT_KEY, &keys, sizeof(keys)));
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_SET_RSP_KEY, &keys, sizeof(keys)));
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_ONLY_ACCEPT_SPECIFIED_SEC_AUTH, &strict, sizeof(strict)));
  atomic_store(&mode, policy);
}

static void gap_event(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
  switch (event) {
    case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
      assert(param->adv_data_raw_cmpl.status == ESP_BT_STATUS_SUCCESS);
      ESP_ERROR_CHECK(esp_ble_gap_start_advertising(&parameters));
      break;
    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
      assert(param->adv_start_cmpl.status == ESP_BT_STATUS_SUCCESS);
      printf("SEC READY bonds=%d mode=%d\n", esp_ble_get_bond_device_num(), atomic_load(&mode));
      break;
    case ESP_GAP_BLE_SEC_REQ_EVT:
      if (atomic_load(&mode) == HOLD) {
        puts("SEC REQUEST held");
        break;
      }
      printf("SEC REQUEST accept=%d\n", atomic_load(&mode) != REJECT);
      ESP_ERROR_CHECK(esp_ble_gap_security_rsp(param->ble_security.ble_req.bd_addr, atomic_load(&mode) != REJECT));
      break;
    case ESP_GAP_BLE_KEY_EVT:
      atomic_fetch_add(&key_events, 1);
      break;
    case ESP_GAP_BLE_AUTH_CMPL_EVT: {
      const esp_ble_auth_cmpl_t *auth = &param->ble_security.auth_cmpl;
      if (auth->success) atomic_fetch_add(&authentications, 1);
      printf("SEC AUTH success=%d auth=0x%02x reason=0x%02x bonds=%d keys=%u\n",
             auth->success, auth->auth_mode, auth->success ? 0 : auth->fail_reason,
             esp_ble_get_bond_device_num(), atomic_load(&key_events));
      break;
    }
    default: break;
  }
}

static void gatt_event(esp_gatts_cb_event_t event, esp_gatt_if_t interface,
                       esp_ble_gatts_cb_param_t *param) {
  switch (event) {
    case ESP_GATTS_REG_EVT:
      assert(param->reg.status == ESP_GATT_OK);
      ESP_ERROR_CHECK(esp_ble_gatts_create_attr_tab(attributes, interface, 3, 0));
      break;
    case ESP_GATTS_CREAT_ATTR_TAB_EVT:
      assert(param->add_attr_tab.status == ESP_GATT_OK && param->add_attr_tab.num_handle == 3);
      ESP_ERROR_CHECK(esp_ble_gatts_start_service(param->add_attr_tab.handles[0]));
      break;
    case ESP_GATTS_START_EVT:
      assert(param->start.status == ESP_GATT_OK);
      ESP_ERROR_CHECK(esp_ble_gap_config_adv_data_raw(advertisement, sizeof(advertisement)));
      break;
    case ESP_GATTS_CONNECT_EVT:
      printf("SEC CONNECT count=%u\n", atomic_fetch_add(&connections, 1) + 1);
      break;
    case ESP_GATTS_DISCONNECT_EVT:
      printf("SEC DISCONNECT count=%u reason=0x%02x\n",
             atomic_fetch_add(&disconnections, 1) + 1, param->disconnect.reason);
      ESP_ERROR_CHECK(esp_ble_gap_start_advertising(&parameters));
      break;
    default: break;
  }
}

static void clear_bonds(void) {
  int count = esp_ble_get_bond_device_num();
  if (!count) { puts("SEC CLEARED"); return; }
  esp_ble_bond_dev_t *bonds = calloc(count, sizeof(*bonds));
  assert(bonds);
  ESP_ERROR_CHECK(esp_ble_get_bond_device_list(&count, bonds));
  for (int i = 0; i < count; i++) ESP_ERROR_CHECK(esp_ble_remove_bond_device(bonds[i].bd_addr));
  free(bonds);
  for (int i = 0; i < 500 && esp_ble_get_bond_device_num(); i++) vTaskDelay(pdMS_TO_TICKS(10));
  puts(esp_ble_get_bond_device_num() ? "SEC ERROR clear timeout" : "SEC CLEARED");
}

void app_main(void) {
  ESP_ERROR_CHECK(nvs_flash_init());
  ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));
  esp_bt_controller_config_t config = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(esp_bt_controller_init(&config));
  ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
  ESP_ERROR_CHECK(esp_bluedroid_init());
  ESP_ERROR_CHECK(esp_bluedroid_enable());
  configure_security(ACCEPT);
  ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_event));
  ESP_ERROR_CHECK(esp_ble_gatts_register_callback(gatt_event));
  ESP_ERROR_CHECK(esp_ble_gatts_app_register(0));
  ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0, 256, 512, 0, NULL, 0));
  uart_vfs_dev_use_driver(UART_NUM_0);
  setvbuf(stdin, NULL, _IONBF, 0);
  char command[32];
  while (fgets(command, sizeof(command), stdin)) {
    command[strcspn(command, "\r\n")] = 0;
    if (!strcmp(command, "STATUS")) {
      printf("SEC STATUS mode=%d bonds=%d connections=%u disconnections=%u auth=%u keys=%u\n",
             atomic_load(&mode), esp_ble_get_bond_device_num(), atomic_load(&connections),
             atomic_load(&disconnections), atomic_load(&authentications), atomic_load(&key_events));
    } else if (atomic_load(&connections) != atomic_load(&disconnections)) {
      puts("SEC ERROR connected");
    } else if (!strcmp(command, "CLEAR")) {
      clear_bonds();
    } else if (!strcmp(command, "REBOOT")) {
      esp_restart();
    } else {
      int policy = !strcmp(command, "ACCEPT") ? ACCEPT : !strcmp(command, "REJECT") ? REJECT
          : !strcmp(command, "NO_BOND") ? NO_BOND : !strcmp(command, "LEGACY") ? LEGACY
          : !strcmp(command, "HOLD") ? HOLD : -1;
      if (policy < 0) puts("SEC ERROR command");
      else { configure_security(policy); printf("SEC MODE %d\n", policy); }
    }
    fflush(stdout);
  }
  assert(false);
}
