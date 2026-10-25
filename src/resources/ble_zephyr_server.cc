// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#if defined(TOIT_ZEPHYR) && CONFIG_BT
#include "ble_zephyr_server.h"
#include "ble_zephyr_lock.h"
#include <new>

namespace toit {
K_MUTEX_DEFINE(ble_zephyr_callback_mutex);

ssize_t BleLocalAttribute::read(bt_conn* connection, const bt_gatt_attr* attr,
                              void* buffer, uint16_t length, uint16_t offset) {
  auto self = static_cast<BleLocalAttribute*>(attr->user_data);
  CallbackLock lock;
  if (!self->owner || !self->has_value) return BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
  if (self->characteristic && !(self->properties & BT_GATT_CHRC_READ)) {
    return BT_GATT_ERR(BT_ATT_ERR_READ_NOT_PERMITTED);
  }
  return bt_gatt_attr_read(connection, attr, buffer, length, offset, self->value.bytes, self->value.length);
}
ssize_t BleLocalAttribute::write(bt_conn* connection, const bt_gatt_attr* attr,
    const void* buffer, uint16_t length, uint16_t offset, uint8_t flags) {
  (void)connection;
  auto self = static_cast<BleLocalAttribute*>(attr->user_data);
  CallbackLock lock;
  if (!self->owner || !self->received) return BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
  if (flags & (BT_GATT_WRITE_FLAG_PREPARE | BT_GATT_WRITE_FLAG_EXECUTE)) return BT_GATT_ERR(BT_ATT_ERR_NOT_SUPPORTED);
  if (self->characteristic &&
      !(self->properties & ((flags & BT_GATT_WRITE_FLAG_CMD) ? BT_GATT_CHRC_WRITE_WITHOUT_RESP : BT_GATT_CHRC_WRITE))) {
    return BT_GATT_ERR(BT_ATT_ERR_WRITE_NOT_PERMITTED);
  }
  if (offset) return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
  if (length > BleZephyrValue::CAPACITY) return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
  if (self->receive_error) return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES);
  if (!self->received->push(buffer, length)) {
    self->received->clear();
    self->receive_error = -ENOBUFS;
    self->notify_received(self->owner);
    return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES);
  }
  self->notify_received(self->owner);
  return length;
}
ssize_t BleLocalAttribute::validate_ccc(bt_conn* connection, const bt_gatt_attr* attr, uint16_t value) {
  auto ccc = CONTAINER_OF(static_cast<bt_gatt_ccc_managed_user_data*>(attr->user_data), Ccc, data);
  CallbackLock lock;
  auto self = ccc->attribute;
  uint16_t allowed = ((self->properties & BT_GATT_CHRC_NOTIFY) ? BT_GATT_CCC_NOTIFY : 0) |
      ((self->properties & BT_GATT_CHRC_INDICATE) ? BT_GATT_CCC_INDICATE : 0);
  if (!self->owner) return BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
  if (value & ~allowed) return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
  if (self->encryption_required(value) &&
      (!connection || bt_conn_get_security(connection) < BT_SECURITY_L2)) {
    return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_ENCRYPTION);
  }
  return sizeof(value);
}
int BleLocalService::prepare() {
  unsigned count = 1;
  for (auto p = characteristics; p; p = p->next) {
    count += 2;
    if (p->properties & (BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_INDICATE)) ++count;
    for (auto d = p->descriptors; d; d = d->next) ++count;
  }
  auto attrs = new (std::nothrow) bt_gatt_attr[count]();
  if (!attrs) return -ENOMEM;
  unsigned index = 0;
  attrs[index++] = BT_GATT_PRIMARY_SERVICE(&uuid.uuid);
  for (auto p = characteristics; p; p = p->next) {
    p->declaration.uuid = &p->uuid.uuid;
    p->declaration.properties = static_cast<uint8_t>(p->properties);
    attrs[index++] = BT_GATT_ATTRIBUTE(BT_UUID_GATT_CHRC, BT_GATT_PERM_READ,
        bt_gatt_attr_read_chrc, nullptr, &p->declaration);
    p->deployed = &attrs[index];
    attrs[index++] = BT_GATT_ATTRIBUTE(&p->uuid.uuid, p->permissions,
        BleLocalAttribute::read, BleLocalAttribute::write, p);
    if (p->properties & (BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_INDICATE)) {
      p->ccc.data.cfg_write = BleLocalAttribute::validate_ccc;
      attrs[index++] = BT_GATT_CCC_MANAGED(&p->ccc.data, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE);
    }
    for (auto d = p->descriptors; d; d = d->next) {
      d->deployed = &attrs[index];
      attrs[index++] = BT_GATT_ATTRIBUTE(&d->uuid.uuid, d->permissions,
          BleLocalAttribute::read, BleLocalAttribute::write, d);
    }
  }
  definition.attrs = attrs;
  definition.attr_count = count;
  prepared = true;
  return 0;
}

}  // namespace toit
#endif
