// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include "ble_zephyr_data.h"
#include <zephyr/bluetooth/gatt.h>

namespace toit {
class BlePeripheralManagerResource;
struct BleLocalService;
union BleLocalUuid {
  bt_uuid uuid;
  bt_uuid_16 u16;
  bt_uuid_128 u128;
  bool set(const uint8_t* bytes, size_t length) {
    if (length == 2) {
      u16.uuid.type = BT_UUID_TYPE_16;
      u16.val = (bytes[0] << 8) | bytes[1];
    } else if (length == 4 || length == 16) {
      // ATT declarations support only 16- and 128-bit UUIDs. In particular,
      // Zephyr's declaration readers treat every non-16 UUID as bt_uuid_128.
      BleZephyrUuid display;
      display.set(bytes, length);
      uint8_t canonical[16];
      display.canonical(canonical);
      u128.uuid.type = BT_UUID_TYPE_128;
      for (unsigned i = 0; i < 16; ++i) u128.val[i] = canonical[15 - i];
    } else return false;
    return true;
  }
};
struct BleLocalAttribute {
  // Toit-only property bits; the GATT declaration contains only the low byte.
  static constexpr uint16_t NOTIFY_ENCRYPTION_REQUIRED = 0x100;
  static constexpr uint16_t INDICATE_ENCRYPTION_REQUIRED = 0x200;
  static bool valid_properties(int properties, bool descriptor) {
    return properties >= 0 && !(properties & ~(descriptor ? 0x3f : 0x33f)) &&
        (!(properties & NOTIFY_ENCRYPTION_REQUIRED) || (properties & BT_GATT_CHRC_NOTIFY)) &&
        (!(properties & INDICATE_ENCRYPTION_REQUIRED) || (properties & BT_GATT_CHRC_INDICATE));
  }
  // Zephyr keeps pointers to these objects until the peripheral is shut down,
  // independently of the lifetime of the Toit resource wrappers.
  BleLocalUuid uuid = {};
  bt_gatt_chrc declaration = {};
  struct Ccc {
    bt_gatt_ccc_managed_user_data data = {};
    BleLocalAttribute* attribute = nullptr;
  } ccc;
  BleZephyrValue value;
  BleZephyrNotifications* received = nullptr;
  // The VM attaches an owner and notification hook before publication, and
  // clears owner under CallbackLock before destroying the wrapper. Keeping
  // this hook independent of the VM lets the native GATT code run unchanged
  // in Zephyr's simulator. The hook runs with the callback mutex held.
  void* owner = nullptr;
  void (*notify_received)(void*) = nullptr;
  bool characteristic = true;
  BleLocalService* service;
  BleLocalAttribute* next = nullptr;
  BleLocalAttribute* descriptors = nullptr;
  bt_gatt_attr* deployed = nullptr;
  uint16_t permissions;
  uint16_t properties;
  bool has_value = false;
  int receive_error = 0;
  BleLocalAttribute(BleLocalService* service, uint16_t properties, uint16_t permissions)
      : service(service), permissions(permissions), properties(properties) { ccc.attribute = this; }
  ~BleLocalAttribute() {
    delete received;
    while (descriptors) { auto p = descriptors; descriptors = p->next; delete p; }
  }
  static ssize_t read(bt_conn*, const bt_gatt_attr*, void*, uint16_t, uint16_t);
  static ssize_t write(bt_conn*, const bt_gatt_attr*, const void*, uint16_t, uint16_t, uint8_t);
  static ssize_t validate_ccc(bt_conn*, const bt_gatt_attr*, uint16_t);
  bool encryption_required(uint16_t ccc_value) const {
    return ((ccc_value & BT_GATT_CCC_NOTIFY) && (properties & NOTIFY_ENCRYPTION_REQUIRED)) ||
        ((ccc_value & BT_GATT_CCC_INDICATE) && (properties & INDICATE_ENCRYPTION_REQUIRED));
  }
  bt_gatt_attr notification_attribute(bool indication) const {
    auto result = *deployed;
    // A private attribute copy lets Zephyr enforce send-time security without
    // changing ordinary reads or the security policy of the other CCC mode.
    if (encryption_required(indication ? BT_GATT_CCC_INDICATE : BT_GATT_CCC_NOTIFY)) {
      result.perm |= BT_GATT_PERM_READ_ENCRYPT;
    }
    return result;
  }
};
struct BleLocalService {
  BleLocalUuid uuid = {};
  bt_gatt_service definition = {};
  BlePeripheralManagerResource* manager;
  BleLocalService* next = nullptr;
  BleLocalAttribute* characteristics = nullptr;
  unsigned wrappers = 1;
  unsigned attribute_count = 1;
  bool registered = false, prepared = false;
  explicit BleLocalService(BlePeripheralManagerResource* manager) : manager(manager) {}
  ~BleLocalService() {
    delete[] definition.attrs;
    while (characteristics) { auto p = characteristics; characteristics = p->next; delete p; }
  }
  int prepare();
};
}  // namespace toit
