// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only. See LICENSE in the repository root.

#include "../top.h"

#if defined(TOIT_ESP32) && (CONFIG_IDF_TARGET_ESP32 || CONFIG_IDF_TARGET_ESP32S3) && CONFIG_BT_CONTROLLER_ONLY

#include <esp_bt.h>
#include <esp_heap_caps.h>
#include <esp_log.h>
#include <esp_memory_utils.h>
#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../event_sources/ev_queue_esp32.h"
#include "ble_hci_queue.h"
#include "ble_hci_owner.h"

namespace toit {

class BleHciResource;
static portMUX_TYPE callback_lock = portMUX_INITIALIZER_UNLOCKED;
// Detaching callbacks must not admit another scheduler thread during shutdown.
static ble_hci::ControllerOwner<BleHciResource> controller_owner;

class BleHciResource : public EventQueueResource {
 public:
  TAG(BleHciResource);
  BleHciResource(ResourceGroup* group, QueueHandle_t queue) : EventQueueResource(group, queue) {}

  void operator delete(void* memory) { heap_caps_free(memory); }

  ~BleHciResource() override {
    shut_down();
    vQueueDelete(queue());
    portENTER_CRITICAL(&callback_lock);
    controller_owner.release(this);
    portEXIT_CRITICAL(&callback_lock);
  }

  esp_err_t shut_down() {
    detach_callbacks();
    esp_err_t first_error = ESP_OK;
    if (enabled_) {
      enabled_ = false;
      esp_err_t error = esp_bt_controller_disable();
      if (error != ESP_OK) {
        ESP_LOGE("ToitVHCI", "Controller disable failed: %d", error);
        first_error = error;
      }
    }
    if (initialized_) {
      initialized_ = false;
      esp_err_t error = esp_bt_controller_deinit();
      if (error != ESP_OK) {
        ESP_LOGE("ToitVHCI", "Controller deinit failed: %d", error);
        if (first_error == ESP_OK) first_error = error;
      }
    }
    return first_error;
  }

  bool claim() {
    portENTER_CRITICAL(&callback_lock);
    bool available = controller_owner.claim(this);
    portEXIT_CRITICAL(&callback_lock);
    return available;
  }

  void detach_callbacks() {
    // The callbacks hold this lock for their entire access to the resource.
    portENTER_CRITICAL(&callback_lock);
    controller_owner.detach(this);
    portEXIT_CRITICAL(&callback_lock);
  }

  esp_err_t initialize() {
    if (esp_bt_controller_get_status() != ESP_BT_CONTROLLER_STATUS_IDLE) return ESP_ERR_INVALID_STATE;
#if CONFIG_IDF_TARGET_ESP32
    // The dual-mode controller reserves BR/EDR memory even in BLE-only mode;
    // release it to the heap once. It can only be released before the first
    // initialization, and a later failure to release (already done) is fine.
    esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT);
#endif
    esp_bt_controller_config_t config = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    esp_err_t error = esp_bt_controller_init(&config);
    if (error != ESP_OK) return error;
    initialized_ = true;
    error = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    if (error != ESP_OK) return error;
    enabled_ = true;
    static const esp_vhci_host_callback_t callbacks = {send_available, receive_packet};
    return esp_vhci_host_register_callback(&callbacks);
  }

  bool receive_event(word* data) override {
    uint8_t wake;
    if (xQueueReceive(queue(), &wake, 0) != pdTRUE) return false;
    // Readiness is rechecked by each primitive. Coalesced wakes can serve both
    // RX and TX, without relying on a count of callback invocations.
    *data = 3;
    return true;
  }

  ble_hci::PacketQueue<8, 1029> packets;

#ifdef TOIT_BLE_HCI_TESTING
  esp_err_t test_stop_controller(bool deinitialize) {
    // Deliberately leave one ownership flag stale so close encounters a real
    // ESP-IDF invalid-state error. Only isolated fault-test builds expose this.
    esp_err_t error = esp_bt_controller_disable();
    if (error != ESP_OK || !deinitialize) return error;
    error = esp_bt_controller_deinit();
    if (error == ESP_OK) enabled_ = false;
    return error;
  }
  ble_hci::QueuePush test_inject(const uint8* bytes, unsigned length) {
    portENTER_CRITICAL(&callback_lock);
    auto result = enqueue(bytes, length);
    portEXIT_CRITICAL(&callback_lock);
    return result;
  }
#endif

 private:
  ble_hci::QueuePush enqueue(const uint8* bytes, unsigned length) {
    auto result = packets.push(bytes, length);
    wake();
    return result;
  }
  void wake() {
    uint8_t wake = 1;
    // A full one-element queue already contains the required wakeup. Do not
    // overwrite it: overwriting a queue-set member can lose notifications.
    xQueueSend(queue(), &wake, 0);
  }
  static void send_available() {
    portENTER_CRITICAL(&callback_lock);
    auto callback_target = controller_owner.target();
    if (callback_target) callback_target->wake();
    portEXIT_CRITICAL(&callback_lock);
  }
  static int receive_packet(uint8_t* bytes, uint16_t length) {
    portENTER_CRITICAL(&callback_lock);
    auto callback_target = controller_owner.target();
    if (callback_target) {
      callback_target->enqueue(bytes, length);
    }
    portEXIT_CRITICAL(&callback_lock);
    // Returning an error is not a retry protocol. Queue faults are delivered to
    // the Toit owner; only advertising reports may be dropped without failure.
    return 0;
  }
  bool initialized_ = false;
  bool enabled_ = false;
};

class BleHciResourceGroup : public ResourceGroup {
 public:
  TAG(BleHciResourceGroup);
  explicit BleHciResourceGroup(Process* process)
      : ResourceGroup(process, EventQueueEventSource::instance()) {}
  void tear_down() override {
    if (resource_) resource_->detach_callbacks();
    ResourceGroup::tear_down();
  }
 private:
  void on_register_resource(Resource* resource) override {
    resource_ = static_cast<BleHciResource*>(resource);
  }
  void on_unregister_resource(Resource* resource) override { resource_ = null; }
  uint32_t on_event(Resource* resource, word data, uint32_t state) override { return state | data; }
  BleHciResource* resource_ = null;
};

MODULE_IMPLEMENTATION(ble_hci, MODULE_BLE_HCI)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto group = _new BleHciResourceGroup(process);
  if (!group) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(open_management) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(open) {
  ARGS(BleHciResourceGroup, group, int, adapter);
  if (adapter != 0) FAIL(OUT_OF_RANGE);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  QueueHandle_t queue = xQueueCreate(BLE_HCI_QUEUE_SIZE, sizeof(uint8_t));
  if (!queue) FAIL(MALLOC_FAILED);
  // Hardware atomics cannot operate on PSRAM. Keep the entire ingress queue,
  // including its counters, in internal RAM even when the managed heap uses
  // PSRAM. This translation unit may enable hardware atomics independently of
  // IDF's workaround for ordinary allocations in other translation units.
  void* memory = heap_caps_malloc(sizeof(BleHciResource), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (!memory) {
    vQueueDelete(queue);
    FAIL(MALLOC_FAILED);
  }
  if (!esp_ptr_internal(memory)) {
    heap_caps_free(memory);
    vQueueDelete(queue);
    FAIL(ERROR);
  }
  auto resource = new (memory) BleHciResource(group, queue);
  if (!resource->claim()) {
    delete resource;
    FAIL(ALREADY_IN_USE);
  }
  // Register the still-empty wake queue before enabling controller callbacks.
  group->register_resource(resource);
  esp_err_t error = resource->initialize();
  if (error != ESP_OK) {
    resource->detach_callbacks();
    group->unregister_resource(resource);
    return Primitive::os_error(error, process);
  }
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(receive) {
  ARGS(BleHciResource, resource, int, limit);
  if (limit < 1 || limit > ByteArray::max_internal_size_in_process()) FAIL(OUT_OF_RANGE);
  ByteArray* packet = null;
  bool too_large = false;
  auto result = resource->packets.receive([&](unsigned size) -> uint8_t* {
    if (size > static_cast<unsigned>(limit)) {
      too_large = true;
      return nullptr;
    }
    packet = process->allocate_byte_array(size);
    return packet ? ByteArray::Bytes(packet).address() : nullptr;
  });
  if (too_large) FAIL(OUT_OF_RANGE);
  switch (result) {
    case ble_hci::QueueReceive::empty: return process->null_object();
    case ble_hci::QueueReceive::allocation_failed: FAIL(ALLOCATION_FAILED);
    case ble_hci::QueueReceive::failed: FAIL(ERROR);
    case ble_hci::QueueReceive::ready: return packet;
  }
  UNREACHABLE();
}

PRIMITIVE(send) {
  ARGS(BleHciResource, resource, Blob, packet);
  if (resource->packets.fault() != ble_hci::QueueFault::none) FAIL(ERROR);
  int length = packet.length();
  const uint8* bytes = packet.address();
  bool command = length >= 4 && bytes[0] == 1 && length == 4 + bytes[3];
  bool acl = length >= 5 && bytes[0] == 2 && length == 5 + bytes[3] + (bytes[4] << 8);
  if ((!command && !acl) || length > 1029) FAIL(INVALID_ARGUMENT);
  if (!esp_vhci_host_check_send_available()) return BOOL(false);
  // IDF's own VHCI adapter frees command storage and returns from stack-backed
  // ACL storage after this call. Do not retain the managed pointer or hold a
  // FreeRTOS critical section across the call.
  esp_vhci_host_send_packet(const_cast<uint8*>(bytes), length);
  return BOOL(true);
}

PRIMITIVE(close) {
  ARGS(BleHciResourceGroup, group, BleHciResource, resource);
  if (resource->resource_group() != group) FAIL(INVALID_ARGUMENT);
  esp_err_t error = resource->shut_down();
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  // The resource is gone. Use a preallocated error so an allocation retry
  // cannot repeat teardown with the cleared proxy.
  if (error != ESP_OK) FAIL(HARDWARE_ERROR);
  return process->null_object();
}

PRIMITIVE(diagnostics) {
  ARGS(BleHciResource, resource);
  ByteArray* result = process->allocate_byte_array(20);
  if (!result) FAIL(ALLOCATION_FAILED);
  // Fixed-width fields avoid integer allocation or managed pointers in callbacks.
  // Fields are sampled independently while callbacks may continue producing.
  unsigned values[] = {8, resource->packets.queued(), resource->packets.high_water(),
      resource->packets.scan_drops(), static_cast<unsigned>(resource->packets.fault())};
  uint8* bytes = ByteArray::Bytes(result).address();
  for (unsigned i = 0; i < 5; i++) {
    for (unsigned j = 0; j < 4; j++) bytes[4 * i + j] = values[i] >> (8 * j);
  }
  return result;
}

// The controller's power levels in dBm, indexed by esp_power_level_t.
#if CONFIG_IDF_TARGET_ESP32
static const int8 TX_POWER_LEVELS[] = {-12, -9, -6, -3, 0, 3, 6, 9};
#else
static const int8 TX_POWER_LEVELS[] = {-24, -21, -18, -15, -12, -9, -6, -3, 0, 3, 6, 9, 12, 15, 18, 20};
#endif
static const int TX_POWER_LEVEL_COUNT = sizeof(TX_POWER_LEVELS) / sizeof(TX_POWER_LEVELS[0]);

// Action 0 reads the advertising power, 1 sets advertising, scanning and
// default power to the level closest to dbm, 2 only rounds dbm. Reading and
// setting need an enabled controller and return null otherwise; the vendor
// API is global, so no transport resource is involved.
PRIMITIVE(tx_power) {
  ARGS(int, action, int, dbm);
  if (action < 0 || action > 2) FAIL(INVALID_ARGUMENT);
  int best = 0;
  for (int i = 1; i < TX_POWER_LEVEL_COUNT; i++) {
    int distance = TX_POWER_LEVELS[i] - dbm;
    int best_distance = TX_POWER_LEVELS[best] - dbm;
    if (distance < 0) distance = -distance;
    if (best_distance < 0) best_distance = -best_distance;
    if (distance < best_distance) best = i;
  }
  if (action == 2) return Smi::from(TX_POWER_LEVELS[best]);
  if (esp_bt_controller_get_status() != ESP_BT_CONTROLLER_STATUS_ENABLED) return process->null_object();
  if (action == 0) {
    int index = static_cast<int>(esp_ble_tx_power_get(ESP_BLE_PWR_TYPE_ADV));
    if (index < 0 || index >= TX_POWER_LEVEL_COUNT) FAIL(ERROR);
    return Smi::from(TX_POWER_LEVELS[index]);
  }
  auto level = static_cast<esp_power_level_t>(best);
  esp_err_t error = esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_DEFAULT, level);
  if (error == ESP_OK) error = esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_ADV, level);
  if (error == ESP_OK) error = esp_ble_tx_power_set(ESP_BLE_PWR_TYPE_SCAN, level);
  if (error != ESP_OK) return Primitive::os_error(error, process);
  return Smi::from(TX_POWER_LEVELS[best]);
}

PRIMITIVE(test) {
#ifdef TOIT_BLE_HCI_TESTING
  ARGS(BleHciResource, resource, int, action, Blob, packet);
  switch (action) {
    case 2: return Smi::from(static_cast<int>(resource->test_inject(packet.address(), packet.length())));
    case 3: return Smi::from(resource->test_stop_controller(false));
    case 4: return Smi::from(resource->test_stop_controller(true));
    default: FAIL(INVALID_ARGUMENT);
  }
#else
  FAIL(UNIMPLEMENTED);
#endif
}

} // namespace toit
#endif
