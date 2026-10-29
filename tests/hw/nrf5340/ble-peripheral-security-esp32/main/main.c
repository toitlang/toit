// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
// Independent Bluedroid central. Logs outcomes and counts, never key material.
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
#include "esp_gattc_api.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"

enum { READY, FOUND, OPENED, SERVICE, SEARCHED, AUTH, READ, WROTE, CLOSED, REMOVED, REGISTERED, NOTIFIED };
typedef struct {
  int type, status, address_type;
  uint16_t connection, start, end, length;
  uint8_t address[6], data[32];
} event_t;
static QueueHandle_t events;
static esp_gatt_if_t client;
static atomic_bool scanning;
static atomic_bool clearing_volatile_peer;
static atomic_uint authentications, key_events, connections, disconnections;
static bool bonding = true;
static esp_ble_scan_params_t scan_parameters = {
  .scan_type = BLE_SCAN_TYPE_ACTIVE, .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
  .scan_filter_policy = BLE_SCAN_FILTER_ALLOW_ALL, .scan_interval = 0x50,
  .scan_window = 0x30, .scan_duplicate = BLE_SCAN_DUPLICATE_DISABLE,
};

static void emit(event_t event) { assert(xQueueSend(events, &event, 0) == pdTRUE); }

static void gap_event(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
  switch (event) {
    case ESP_GAP_BLE_SCAN_PARAM_SET_COMPLETE_EVT:
      assert(param->scan_param_cmpl.status == ESP_BT_STATUS_SUCCESS);
      emit((event_t){.type = READY});
      break;
    case ESP_GAP_BLE_SCAN_RESULT_EVT: {
      if (param->scan_rst.search_evt != ESP_GAP_SEARCH_INQ_RES_EVT || !atomic_load(&scanning)) break;
      uint8_t length;
      uint8_t *name = esp_ble_resolve_adv_data(param->scan_rst.ble_adv, ESP_BLE_AD_TYPE_NAME_CMPL, &length);
      if (!name || length != 12 || memcmp(name, "toit-nrf-sec", 12)) break;
      if (!atomic_exchange(&scanning, false)) break;
      event_t found = {.type = FOUND, .address_type = param->scan_rst.ble_addr_type};
      memcpy(found.address, param->scan_rst.bda, 6);
      emit(found);
      break;
    }
    case ESP_GAP_BLE_SEC_REQ_EVT:
      ESP_ERROR_CHECK(esp_ble_gap_security_rsp(param->ble_security.ble_req.bd_addr, true));
      break;
    case ESP_GAP_BLE_KEY_EVT:
      atomic_fetch_add(&key_events, 1);
      printf("CEN KEY type=0x%02x\n", param->ble_security.ble_key.key_type);
      break;
    case ESP_GAP_BLE_REMOVE_BOND_DEV_COMPLETE_EVT:
      if (atomic_exchange(&clearing_volatile_peer, false)) {
        emit((event_t){.type = REMOVED, .status = param->remove_bond_dev_cmpl.status});
      }
      break;
    case ESP_GAP_BLE_AUTH_CMPL_EVT: {
      const esp_ble_auth_cmpl_t *auth = &param->ble_security.auth_cmpl;
      if (auth->success) atomic_fetch_add(&authentications, 1);
      printf("CEN AUTH success=%d mode=0x%02x reason=0x%02x bonds=%d keys=%u\n",
             auth->success, auth->auth_mode, auth->success ? 0 : auth->fail_reason,
             esp_ble_get_bond_device_num(), atomic_load(&key_events));
      emit((event_t){.type = AUTH, .status = auth->success ? 0 : auth->fail_reason,
                     .data = {auth->auth_mode}});
      break;
    }
    default: break;
  }
}

static void gatt_event(esp_gattc_cb_event_t event, esp_gatt_if_t interface, esp_ble_gattc_cb_param_t *param) {
  switch (event) {
    case ESP_GATTC_REG_EVT:
      assert(param->reg.status == ESP_GATT_OK);
      client = interface;
      ESP_ERROR_CHECK(esp_ble_gap_set_scan_params(&scan_parameters));
      break;
    case ESP_GATTC_OPEN_EVT:
      if (param->open.status == ESP_GATT_OK) atomic_fetch_add(&connections, 1);
      emit((event_t){.type = OPENED, .status = param->open.status, .connection = param->open.conn_id});
      break;
    case ESP_GATTC_SEARCH_RES_EVT:
      if (param->search_res.srvc_id.uuid.len == ESP_UUID_LEN_16 &&
          param->search_res.srvc_id.uuid.uuid.uuid16 == 0xfff0) {
        emit((event_t){.type = SERVICE, .start = param->search_res.start_handle,
                       .end = param->search_res.end_handle});
      }
      break;
    case ESP_GATTC_SEARCH_CMPL_EVT:
      emit((event_t){.type = SEARCHED, .status = param->search_cmpl.status});
      break;
    case ESP_GATTC_READ_DESCR_EVT:
    case ESP_GATTC_READ_CHAR_EVT: {
      event_t result = {.type = READ, .status = param->read.status, .length = param->read.value_len};
      assert(result.length <= sizeof(result.data));
      if (result.length) memcpy(result.data, param->read.value, result.length);
      emit(result);
      break;
    }
    case ESP_GATTC_WRITE_DESCR_EVT:
    case ESP_GATTC_WRITE_CHAR_EVT:
      emit((event_t){.type = WROTE, .status = param->write.status});
      break;
    case ESP_GATTC_REG_FOR_NOTIFY_EVT:
      emit((event_t){.type = REGISTERED, .status = param->reg_for_notify.status});
      break;
    case ESP_GATTC_SRVC_CHG_EVT:
      puts("CEN SERVICE CHANGED");
      break;
    case ESP_GATTC_NOTIFY_EVT: {
      event_t result = {.type = NOTIFIED, .start = param->notify.handle,
                        .address_type = param->notify.is_notify, .length = param->notify.value_len};
      assert(result.length <= sizeof(result.data));
      if (result.length) memcpy(result.data, param->notify.value, result.length);
      emit(result);
      break;
    }
    case ESP_GATTC_DISCONNECT_EVT:
      printf("CEN DISCONNECT count=%u reason=0x%02x\n",
             atomic_fetch_add(&disconnections, 1) + 1, param->disconnect.reason);
      emit((event_t){.type = CLOSED});
      break;
    default: break;
  }
}

static event_t take(int type) {
  event_t event;
  assert(xQueueReceive(events, &event, pdMS_TO_TICKS(15000)) == pdTRUE);
  if (event.type != type || event.status) {
    printf("CEN ERROR expected=%d type=%d status=0x%x\n", type, event.type, event.status);
    fflush(stdout);
    abort();
  }
  return event;
}

static uint16_t characteristic(uint16_t connection, event_t service, uint16_t id) {
  esp_bt_uuid_t uuid = {.len = ESP_UUID_LEN_16, .uuid.uuid16 = id};
  esp_gattc_char_elem_t result;
  uint16_t count = 1;
  assert(esp_ble_gattc_get_char_by_uuid(client, connection, service.start, service.end, uuid, &result, &count) == ESP_GATT_OK);
  assert(count == 1);
  return result.char_handle;
}

static event_t connect_peer(uint16_t *connection) {
  assert(uxQueueMessagesWaiting(events) == 0);
  atomic_store(&scanning, true);
  ESP_ERROR_CHECK(esp_ble_gap_start_scanning(10));
  event_t found = take(FOUND);
  ESP_ERROR_CHECK(esp_ble_gap_stop_scanning());
  ESP_ERROR_CHECK(esp_ble_gattc_open(client, found.address, found.address_type, true));
  *connection = take(OPENED).connection;
  return found;
}

static void finish_run(uint16_t connection, uint16_t control, event_t found, bool reject) {
  uint8_t done[] = "done";
  ESP_ERROR_CHECK(esp_ble_gattc_write_char(client, connection, control, sizeof(done) - 1, done,
                                         ESP_GATT_WRITE_TYPE_NO_RSP, ESP_GATT_AUTH_REQ_NONE));
  bool wrote = false, closed = false;
  for (int i = 0; i < 2; i++) {
    event_t event;
    assert(xQueueReceive(events, &event, pdMS_TO_TICKS(15000)) == pdTRUE);
    assert(!event.status);
    if (event.type == WROTE) { assert(!wrote); wrote = true; }
    else { assert(event.type == CLOSED && !closed); closed = true; }
  }
  assert(wrote && closed);
  if (!bonding) {
    // Bluedroid keeps the SC PENC key in its RAM device record even without
    // a stored bond. Its ENCRYPT API otherwise retries that old key on the
    // next link. Remove the disconnected test peer to request fresh pairing.
    assert(esp_ble_get_bond_device_num() == 0);
    atomic_store(&clearing_volatile_peer, true);
    ESP_ERROR_CHECK(esp_ble_remove_bond_device(found.address));
    event_t removed;
    assert(xQueueReceive(events, &removed, pdMS_TO_TICKS(5000)) == pdTRUE && removed.type == REMOVED);
    // BTA removes the RAM record before reporting completion. BTC then tries
    // to delete NVS keys, which can report FAIL because this peer has no bond.
    assert(removed.status == ESP_BT_STATUS_SUCCESS || removed.status == ESP_BT_STATUS_FAIL);
    assert(esp_ble_get_bond_device_num() == 0);
    printf("CEN VOLATILE PEER CLEARED storage_status=%d\n", removed.status);
  }
  printf("CEN %sPASS connections=%u auth=%u keys=%u bonds=%d\n", reject ? "REJECT " : "", atomic_load(&connections),
         atomic_load(&authentications), atomic_load(&key_events), esp_ble_get_bond_device_num());
}

static void run(bool reject) {
  uint16_t connection;
  event_t found = connect_peer(&connection);
  ESP_ERROR_CHECK(esp_ble_set_encryption(found.address, ESP_BLE_SEC_ENCRYPT));
  if (reject) {
    bool failed = false, closed = false;
    for (int i = 0; i < 2; i++) {
      event_t event;
      assert(xQueueReceive(events, &event, pdMS_TO_TICKS(15000)) == pdTRUE);
      if (event.type == AUTH) { assert(event.status && !failed); failed = true; }
      else { assert(event.type == CLOSED && !closed); closed = true; }
    }
    assert(failed && closed && esp_ble_get_bond_device_num() == 0);
    // Prove that an ordinary link and plaintext control remain usable after
    // rejected pairing. The protected characteristic is never written.
    connect_peer(&connection);
  } else {
    event_t auth = take(AUTH);
    assert((auth.data[0] & 0x08) != 0);
    assert(esp_ble_get_bond_device_num() == (bonding ? 1 : 0));
  }
  esp_bt_uuid_t uuid = {.len = ESP_UUID_LEN_16, .uuid.uuid16 = 0xfff0};
  ESP_ERROR_CHECK(esp_ble_gattc_search_service(client, connection, &uuid));
  event_t service = take(SERVICE);
  take(SEARCHED);
  uint16_t value = characteristic(connection, service, 0xfff1);
  uint16_t control = characteristic(connection, service, 0xfff2);
  if (!reject) {
    ESP_ERROR_CHECK(esp_ble_gattc_read_char(client, connection, value, ESP_GATT_AUTH_REQ_NONE));
    event_t read = take(READ);
    assert(read.length == 13 && !memcmp(read.data, "nrf-secure-v1", 13));
    uint8_t write[] = "from-esp-sec";
    ESP_ERROR_CHECK(esp_ble_gattc_write_char(client, connection, value, sizeof(write) - 1, write,
                                           ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE));
    take(WROTE);
    for (int attempt = 0; ; attempt++) {
      assert(attempt < 50);
      ESP_ERROR_CHECK(esp_ble_gattc_read_char(client, connection, value, ESP_GATT_AUTH_REQ_NONE));
      read = take(READ);
      if (read.length == 7 && !memcmp(read.data, "ack-sec", 7)) break;
      vTaskDelay(pdMS_TO_TICKS(20));
    }
    esp_bt_uuid_t descriptor_uuid = {.len = ESP_UUID_LEN_16, .uuid.uuid16 = 0xfff3};
    esp_gattc_descr_elem_t descriptor;
    uint16_t count = 1;
    assert(esp_ble_gattc_get_descr_by_char_handle(client, connection, value, descriptor_uuid,
                                                &descriptor, &count) == ESP_GATT_OK && count == 1);
    ESP_ERROR_CHECK(esp_ble_gattc_read_char_descr(client, connection, descriptor.handle, ESP_GATT_AUTH_REQ_NONE));
    read = take(READ);
    assert(read.length == 12 && !memcmp(read.data, "desc-initial", 12));
    uint8_t descriptor_write[] = "from-desc-sec";
    ESP_ERROR_CHECK(esp_ble_gattc_write_char_descr(client, connection, descriptor.handle,
        sizeof(descriptor_write) - 1, descriptor_write, ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE));
    take(WROTE);
    for (int attempt = 0; ; attempt++) {
      assert(attempt < 50);
      ESP_ERROR_CHECK(esp_ble_gattc_read_char_descr(client, connection, descriptor.handle, ESP_GATT_AUTH_REQ_NONE));
      read = take(READ);
      if (read.length == 8 && !memcmp(read.data, "ack-desc", 8)) break;
      vTaskDelay(pdMS_TO_TICKS(20));
    }
  }
  finish_run(connection, control, found, reject);
}

// Exercise opposite security policies on two dual-mode characteristics. Before
// pairing, reads and the unprotected mode must work without triggering SMP.
static void run_notifications(void) {
  uint16_t connection;
  event_t found = connect_peer(&connection);
  unsigned initial_auth = atomic_load(&authentications);
  esp_bt_uuid_t uuid = {.len = ESP_UUID_LEN_16, .uuid.uuid16 = 0xfff0};
  ESP_ERROR_CHECK(esp_ble_gattc_search_service(client, connection, &uuid));
  event_t service = take(SERVICE);
  take(SEARCHED);
  uint16_t control = characteristic(connection, service, 0xfff2);
  uint16_t values[2], cccs[2];
  for (unsigned i = 0; i < 2; ++i) {
    values[i] = characteristic(connection, service, i ? 0xfff3 : 0xfff1);
    ESP_ERROR_CHECK(esp_ble_gattc_read_char(client, connection, values[i], ESP_GATT_AUTH_REQ_NONE));
    event_t read = take(READ);
    assert(read.length == 9 && !memcmp(read.data, "plaintext", 9));
    esp_bt_uuid_t ccc_uuid = {.len = ESP_UUID_LEN_16, .uuid.uuid16 = 0x2902};
    esp_gattc_descr_elem_t descriptor;
    uint16_t count = 1;
    assert(esp_ble_gattc_get_descr_by_char_handle(client, connection, values[i], ccc_uuid,
                                                &descriptor, &count) == ESP_GATT_OK && count == 1);
    cccs[i] = descriptor.handle;
    for (unsigned attempt = 0; attempt < 2; ++attempt) {
      // A write command avoids Bluedroid's automatic pairing/retry on an ATT
      // error response. Read back the CCC to prove the server rejected it.
      uint8_t bits[2] = {attempt ? 3 : (i ? 2 : 1), 0};
      ESP_ERROR_CHECK(esp_ble_gattc_write_char_descr(client, connection, cccs[i], 2, bits,
                                                   ESP_GATT_WRITE_TYPE_NO_RSP, ESP_GATT_AUTH_REQ_NONE));
      take(WROTE);
      ESP_ERROR_CHECK(esp_ble_gattc_read_char_descr(client, connection, cccs[i], ESP_GATT_AUTH_REQ_NONE));
      event_t ccc = take(READ);
      assert(ccc.length == 2 && ccc.data[0] == 0 && ccc.data[1] == 0);
      printf("CEN NOTIFY REJECT index=%u bits=%u PASS\n", i, bits[0]);
    }
  }
  for (unsigned step = 0; step < 6; ++step) {
    if (step == 2) {
      assert(atomic_load(&authentications) == initial_auth);
      puts("CEN NOTIFY PLAINTEXT PASS");
      ESP_ERROR_CHECK(esp_ble_set_encryption(found.address, ESP_BLE_SEC_ENCRYPT));
      event_t auth = take(AUTH);
      assert((auth.data[0] & 0x08) != 0 && esp_ble_get_bond_device_num() == 0);
    }
    unsigned index = step < 2 ? step : (step - 2) / 2;
    unsigned mode = step < 2 ? (index ? 1 : 2) : (step % 2 ? 2 : 1);
    uint8_t bits[2] = {mode, 0};
    ESP_ERROR_CHECK(esp_ble_gattc_write_char_descr(client, connection, cccs[index], 2, bits,
                                                 ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE));
    take(WROTE);
    ESP_ERROR_CHECK(esp_ble_gattc_read_char_descr(client, connection, cccs[index], ESP_GATT_AUTH_REQ_NONE));
    event_t ccc = take(READ);
    assert(ccc.length == 2 && ccc.data[0] == mode && ccc.data[1] == 0);
    // A Service Changed indication after pairing clears Bluedroid's local
    // notification registrations. Re-register after ATT/cache work completes.
    ESP_ERROR_CHECK(esp_ble_gattc_register_for_notify(client, found.address, values[index]));
    take(REGISTERED);
    printf("CEN NOTIFY subscribed step=%u mode=%u\n", step, mode);
    uint8_t command[2] = {index, step};
    ESP_ERROR_CHECK(esp_ble_gattc_write_char(client, connection, control, 2, command,
                                           ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE));
    bool wrote = false, received = false;
    for (unsigned i = 0; i < 2; ++i) {
      event_t event;
      BaseType_t received_event = xQueueReceive(events, &event, pdMS_TO_TICKS(15000));
      if (received_event != pdTRUE) {
        printf("CEN NOTIFY TIMEOUT step=%u wrote=%d received=%d\n", step, wrote, received);
      } else if (event.status) {
        printf("CEN NOTIFY ERROR step=%u type=%d status=%d\n", step, event.type, event.status);
      }
      assert(received_event == pdTRUE && !event.status);
      if (event.type == WROTE) { assert(!wrote); wrote = true; }
      else {
        assert(event.type == NOTIFIED && !received);
        assert(event.start == values[index] && event.address_type == (mode == 1));
        assert(event.length == 2 && !memcmp(event.data, command, 2));
        received = true;
      }
    }
    assert(wrote && received);
    printf("CEN NOTIFY step=%u index=%u mode=%u encrypted=%d PASS\n", step, index, mode, step >= 2);
    // Disabling either mode must remain possible, independently of security.
    bits[0] = 0;
    ESP_ERROR_CHECK(esp_ble_gattc_write_char_descr(client, connection, cccs[index], 2, bits,
                                                 ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE));
    take(WROTE);
  }
  finish_run(connection, control, found, false);
}

static void configure(bool bond) {
  esp_ble_auth_req_t auth = bond ? ESP_LE_AUTH_REQ_SC_BOND : ESP_LE_AUTH_REQ_SC_ONLY;
  uint8_t io = ESP_IO_CAP_NONE, size = 16, keys = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_AUTHEN_REQ_MODE, &auth, sizeof(auth)));
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_IOCAP_MODE, &io, sizeof(io)));
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_MAX_KEY_SIZE, &size, sizeof(size)));
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_SET_INIT_KEY, &keys, sizeof(keys)));
  ESP_ERROR_CHECK(esp_ble_gap_set_security_param(ESP_BLE_SM_SET_RSP_KEY, &keys, sizeof(keys)));
  bonding = bond;
}

void app_main(void) {
  events = xQueueCreate(32, sizeof(event_t));
  assert(events);
  ESP_ERROR_CHECK(nvs_flash_init());
  ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));
  esp_bt_controller_config_t config = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(esp_bt_controller_init(&config));
  ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
  ESP_ERROR_CHECK(esp_bluedroid_init());
  ESP_ERROR_CHECK(esp_bluedroid_enable());
  configure(true);
  ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_event));
  ESP_ERROR_CHECK(esp_ble_gattc_register_callback(gatt_event));
  ESP_ERROR_CHECK(esp_ble_gattc_app_register(0));
  take(READY);
  ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0, 256, 512, 0, NULL, 0));
  uart_vfs_dev_use_driver(UART_NUM_0);
  setvbuf(stdin, NULL, _IONBF, 0);
  printf("CEN READY bonds=%d\n", esp_ble_get_bond_device_num());
  char command[32];
  while (fgets(command, sizeof(command), stdin)) {
    command[strcspn(command, "\r\n")] = 0;
    if (!strcmp(command, "RUN")) run(false);
    else if (!strcmp(command, "RUN_NOTIFY")) run_notifications();
    else if (!strcmp(command, "RUN_REJECT")) run(true);
    else if (!strcmp(command, "BOND")) { configure(true); puts("CEN MODE BOND"); }
    else if (!strcmp(command, "NO_BOND")) { configure(false); puts("CEN MODE NO_BOND"); }
    else if (!strcmp(command, "STATUS")) {
      printf("CEN STATUS bonds=%d connections=%u disconnections=%u auth=%u keys=%u\n",
             esp_ble_get_bond_device_num(), atomic_load(&connections), atomic_load(&disconnections),
             atomic_load(&authentications), atomic_load(&key_events));
    } else if (!strcmp(command, "CLEAR")) {
      int count = esp_ble_get_bond_device_num();
      if (count) {
        esp_ble_bond_dev_t *bonds = calloc(count, sizeof(*bonds)); assert(bonds);
        ESP_ERROR_CHECK(esp_ble_get_bond_device_list(&count, bonds));
        for (int i = 0; i < count; i++) ESP_ERROR_CHECK(esp_ble_remove_bond_device(bonds[i].bd_addr));
        free(bonds);
        for (int i = 0; i < 500 && esp_ble_get_bond_device_num(); i++) vTaskDelay(pdMS_TO_TICKS(10));
      }
      assert(esp_ble_get_bond_device_num() == 0);
      puts("CEN CLEARED");
    } else puts("CEN ERROR command");
    fflush(stdout);
  }
  assert(false);
}
