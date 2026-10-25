// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include "ble_zephyr_server.h"
#include "ble_zephyr_lock.h"
#include <zephyr/ztest.h>
#include <new>
#include <initializer_list>
using namespace toit;

// Pinned Zephyr internal entry point used by gatt_notify/gatt_indicate. This
// simulator has SMP disabled, so no connection can satisfy encryption.
extern "C" {
#include "gatt_internal.h"
}

struct Owner {
  unsigned writes = 0;
  static void received(void* pointer) { ++static_cast<Owner*>(pointer)->writes; }
};
struct Fixture {
  BleLocalService service{nullptr};
  Owner owner;
  BleLocalAttribute* value;
  BleLocalAttribute* descriptor;
  Fixture() {
    const uint8_t service_uuid[] = {0x18, 0x0a};
    zassert_true(service.uuid.set(service_uuid, sizeof(service_uuid)));
    value = new BleLocalAttribute(&service,
        BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP | BT_GATT_CHRC_NOTIFY,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE);
    service.characteristics = value;
    const uint8_t value_uuid[] = {0x2a, 0x24};
    zassert_true(value->uuid.set(value_uuid, sizeof(value_uuid)));
    value->owner = &owner;
    value->notify_received = Owner::received;
    value->has_value = true;
    value->received = new BleZephyrNotifications;
    for (unsigned i = 0; i < 512; ++i) {
      uint8_t byte = i & 255;
      zassert_true(value->value.append(&byte, 1));
    }
    descriptor = new BleLocalAttribute(&service, BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE);
    value->descriptors = descriptor;
    const uint8_t descriptor_uuid[] = {0x29, 0x01};
    zassert_true(descriptor->uuid.set(descriptor_uuid, sizeof(descriptor_uuid)));
    descriptor->owner = &owner;
    descriptor->notify_received = Owner::received;
    descriptor->characteristic = false;
    descriptor->received = new BleZephyrNotifications;
    descriptor->has_value = true;  // Explicit empty stored value.
    auto tail = new BleLocalAttribute(&service, BT_GATT_CHRC_READ, BT_GATT_PERM_READ);
    const uint8_t tail_uuid[] = {0x2a, 0x29};
    zassert_true(tail->uuid.set(tail_uuid, sizeof(tail_uuid)));
    value->next = tail;
  }
  void deploy() {
    zassert_equal(service.prepare(), 0);
    zassert_equal(bt_gatt_service_register(&service.definition), 0);
    service.registered = true;
  }
  ~Fixture() {
    if (service.registered) bt_gatt_service_unregister(&service.definition);
  }
};

ZTEST_SUITE(toit_gatt, nullptr, nullptr, nullptr, nullptr, nullptr);

ZTEST(toit_gatt, encrypted_notification_modes) {
  constexpr auto notify = BleLocalAttribute::NOTIFY_ENCRYPTION_REQUIRED;
  constexpr auto indicate = BleLocalAttribute::INDICATE_ENCRYPTION_REQUIRED;
  zassert_false(BleLocalAttribute::valid_properties(-1, false));
  zassert_false(BleLocalAttribute::valid_properties(0x400, false));
  zassert_false(BleLocalAttribute::valid_properties(notify, false));
  zassert_false(BleLocalAttribute::valid_properties(indicate, false));
  for (unsigned flags : {0u, unsigned(notify), unsigned(indicate), unsigned(notify | indicate)}) {
    Fixture fixture;
    auto properties = BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_INDICATE | flags;
    zassert_true(BleLocalAttribute::valid_properties(properties, false));
    zassert_equal(BleLocalAttribute::valid_properties(properties, true), flags == 0);
    fixture.value->properties = properties;
    fixture.deploy();
    auto attrs = fixture.service.definition.attrs;
    uint8_t buffer[8];
    zassert_equal(attrs[1].read(nullptr, &attrs[1], buffer, sizeof(buffer), 0), 5);
    zassert_equal(buffer[0], properties & 0xff);
    // Requiring encrypted notifications must not forbid plaintext reads.
    zassert_equal(bt_gatt_check_perm(nullptr, &attrs[2], BT_GATT_PERM_READ_MASK), 0);
    zassert_equal(attrs[2].read(nullptr, &attrs[2], buffer, sizeof(buffer), 0), sizeof(buffer));
    zassert_equal(fixture.value->ccc.data.cfg_write(nullptr, &attrs[3], 0), 2);
    for (bool indication : {false, true}) {
      bool encrypted = flags & (indication ? indicate : notify);
      auto ccc = indication ? BT_GATT_CCC_INDICATE : BT_GATT_CCC_NOTIFY;
      zassert_equal(fixture.value->ccc.data.cfg_write(nullptr, &attrs[3], ccc),
          encrypted ? BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_ENCRYPTION) : 2);
      // This is also the send-time guard when CCC state has been restored but
      // the peer has not encrypted its new connection yet.
      auto outgoing = fixture.value->notification_attribute(indication);
      zassert_equal(bt_gatt_attr_get_handle(&outgoing), attrs[2].handle);
      zassert_equal(bt_gatt_check_perm(nullptr, &outgoing, BT_GATT_PERM_READ_ENCRYPT_MASK),
          encrypted ? BT_ATT_ERR_AUTHENTICATION : 0);
      zassert_equal(attrs[2].perm, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE);
    }
    // Existing encrypted-read permissions must protect both send modes too.
    attrs[2].perm |= BT_GATT_PERM_READ_ENCRYPT;
    for (bool indication : {false, true}) {
      auto outgoing = fixture.value->notification_attribute(indication);
      zassert_equal(bt_gatt_check_perm(nullptr, &outgoing, BT_GATT_PERM_READ_ENCRYPT_MASK),
          BT_ATT_ERR_AUTHENTICATION);
    }
  }
}

ZTEST(toit_gatt, declaration_encoding_and_ranges) {
  const uint8_t wide[] = {0x12, 0x34, 0x56, 0x78};
  const uint8_t canonical[] = {0x12, 0x34, 0x56, 0x78, 0, 0, 0x10, 0, 0x80, 0, 0, 0x80, 0x5f, 0x9b, 0x34, 0xfb};
  const uint8_t wire[] = {0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 0x78, 0x56, 0x34, 0x12};
  for (unsigned size : {2u, 4u, 16u}) {
    Fixture fixture;
    if (size != 2) {
      auto bytes = size == 4 ? wide : canonical;
      zassert_true(fixture.service.uuid.set(bytes, size));
      zassert_true(fixture.value->uuid.set(bytes, size));
    }
    fixture.deploy();
    auto attrs = fixture.service.definition.attrs;
    zassert_equal(fixture.service.definition.attr_count, 7);
    zassert_equal(fixture.value->deployed, &attrs[2]);
    zassert_equal(fixture.descriptor->deployed, &attrs[4]);
    zassert_equal(fixture.value->next->deployed, &attrs[6]);
    zassert_equal(bt_uuid_cmp(attrs[3].uuid, BT_UUID_GATT_CCC), 0);
    zassert_equal(attrs[6].handle, attrs[0].handle + 6);
    uint8_t buffer[32] = {};
    auto length = attrs[0].read(nullptr, &attrs[0], buffer, sizeof(buffer), 0);
    zassert_equal(length, size == 2 ? 2 : 16);
    if (size == 2) {
      const uint8_t expected[] = {0x0a, 0x18};
      zassert_mem_equal(buffer, expected, 2);
    } else zassert_mem_equal(buffer, wire, sizeof(wire));
    length = attrs[1].read(nullptr, &attrs[1], buffer, sizeof(buffer), 0);
    zassert_equal(length, size == 2 ? 5 : 19);
    zassert_equal(buffer[0], fixture.value->properties);
    zassert_equal(buffer[1] | (buffer[2] << 8), attrs[2].handle);
    if (size == 2) {
      const uint8_t expected[] = {0x24, 0x2a};
      zassert_mem_equal(buffer + 3, expected, 2);
    } else zassert_mem_equal(buffer + 3, wire, sizeof(wire));
  }
}

ZTEST(toit_gatt, stored_reads_offsets_and_empty) {
  Fixture fixture;
  fixture.deploy();
  auto attr = fixture.value->deployed;
  for (unsigned chunk : {1u, 22u, 31u, 255u, 512u}) {
    for (unsigned offset = 0; offset <= 513;) {
      uint8_t buffer[514];
      memset(buffer, 0xee, sizeof(buffer));
      auto length = attr->read(nullptr, attr, buffer + 1, chunk, offset);
      if (offset == 513) {
        zassert_equal(length, BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET));
        break;
      }
      unsigned expected = MIN(chunk, 512 - offset);
      zassert_equal(length, expected);
      zassert_equal(buffer[0], 0xee);
      zassert_equal(buffer[1 + expected], 0xee);
      for (unsigned i = 0; i < expected; ++i) zassert_equal(buffer[1 + i], (offset + i) & 255);
      offset += expected ? expected : 1;
    }
  }
  uint8_t buffer;
  zassert_equal(attr->read(nullptr, attr, &buffer, 0, 0), 0);
  auto empty = fixture.descriptor->deployed;
  zassert_equal(empty->read(nullptr, empty, &buffer, 1, 0), 0);
  zassert_equal(empty->read(nullptr, empty, &buffer, 1, 1), BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET));
  fixture.value->has_value = false;
  zassert_equal(attr->read(nullptr, attr, &buffer, 1, 0), BT_GATT_ERR(BT_ATT_ERR_UNLIKELY));
}

ZTEST(toit_gatt, write_queue_overflow_and_recovery) {
  Fixture fixture;
  fixture.deploy();
  auto attr = fixture.value->deployed;
  uint8_t payload[512];
  for (unsigned round = 0; round < 50; ++round) {
    for (unsigned i = 0; i < 8; ++i) {
      memset(payload, i, sizeof(payload));
      zassert_equal(attr->write(nullptr, attr, payload, i, 0, 0), i);
    }
    memset(payload, 0xff, sizeof(payload));
    for (unsigned i = 0; i < 8; ++i) {
      auto item = fixture.value->received->peek();
      zassert_not_null(item);
      zassert_equal(item->length, i);
      for (unsigned j = 0; j < i; ++j) zassert_equal(item->bytes[j], i);
      fixture.value->received->pop();
    }
    for (unsigned i = 0; i < 8; ++i) zassert_equal(attr->write(nullptr, attr, payload, 1, 0, BT_GATT_WRITE_FLAG_CMD), 1);
    zassert_equal(attr->write(nullptr, attr, payload, 1, 0, 0), BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES));
    zassert_equal(fixture.value->receive_error, -ENOBUFS);
    zassert_is_null(fixture.value->received->peek());
    unsigned before = fixture.owner.writes;
    zassert_equal(attr->write(nullptr, attr, payload, 1, 0, 0), BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_RESOURCES));
    zassert_equal(fixture.owner.writes, before);
    fixture.value->receive_error = 0;  // Same action as consuming the VM error.
    zassert_equal(attr->write(nullptr, attr, payload, 512, 0, 0), 512);
    memset(payload, 0, sizeof(payload));
    zassert_equal(fixture.value->received->peek()->length, 512);
    for (auto byte : fixture.value->received->peek()->bytes) zassert_equal(byte, 0xff);
    fixture.value->received->pop();
    zassert_equal(fixture.owner.writes, (round + 1) * 18);
  }
  for (unsigned i = 0; i < 512; ++i) zassert_equal(fixture.value->value.bytes[i], i & 255);
}

ZTEST(toit_gatt, access_rejections_and_ccc_validation) {
  Fixture fixture;
  fixture.deploy();
  auto attr = fixture.value->deployed;
  uint8_t byte = 42;
  zassert_equal(attr->write(nullptr, attr, &byte, 513, 0, 0), BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN));
  zassert_equal(attr->write(nullptr, attr, &byte, 1, 1, 0), BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET));
  zassert_equal(attr->write(nullptr, attr, &byte, 1, 0, BT_GATT_WRITE_FLAG_PREPARE), BT_GATT_ERR(BT_ATT_ERR_NOT_SUPPORTED));
  zassert_equal(attr->write(nullptr, attr, &byte, 1, 0, BT_GATT_WRITE_FLAG_EXECUTE), BT_GATT_ERR(BT_ATT_ERR_NOT_SUPPORTED));
  fixture.value->properties = BT_GATT_CHRC_WRITE;
  zassert_equal(attr->write(nullptr, attr, &byte, 1, 0, BT_GATT_WRITE_FLAG_CMD), BT_GATT_ERR(BT_ATT_ERR_WRITE_NOT_PERMITTED));
  zassert_equal(attr->read(nullptr, attr, &byte, 1, 0), BT_GATT_ERR(BT_ATT_ERR_READ_NOT_PERMITTED));
  fixture.value->properties = BT_GATT_CHRC_WRITE_WITHOUT_RESP;
  zassert_equal(attr->write(nullptr, attr, &byte, 1, 0, 0), BT_GATT_ERR(BT_ATT_ERR_WRITE_NOT_PERMITTED));
  auto descriptor = fixture.descriptor->deployed;
  zassert_equal(descriptor->write(nullptr, descriptor, &byte, 1, 0, BT_GATT_WRITE_FLAG_CMD), 1);
  auto ccc = &fixture.service.definition.attrs[3];
  for (unsigned enabled = 1; enabled <= 3; ++enabled) {
    fixture.value->properties = ((enabled & 1) ? BT_GATT_CHRC_NOTIFY : 0) | ((enabled & 2) ? BT_GATT_CHRC_INDICATE : 0);
    for (unsigned bits = 0; bits < 8; ++bits) {
      auto expected = (bits & ~enabled) ? BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED) : 2;
      zassert_equal(fixture.value->ccc.data.cfg_write(nullptr, ccc, bits), expected);
    }
  }
}

ZTEST(toit_gatt, detached_owner_and_reregister) {
  for (unsigned cycle = 0; cycle < 100; ++cycle) {
    Fixture fixture;
    auto owner = new Owner;
    fixture.value->owner = owner;
    fixture.deploy();
    auto attr = fixture.value->deployed;
    auto ccc = &fixture.service.definition.attrs[3];
    {
      CallbackLock lock;
      fixture.value->owner = nullptr;
      delete owner;
    }
    uint8_t byte = 42;
    zassert_equal(attr->read(nullptr, attr, &byte, 1, 0), BT_GATT_ERR(BT_ATT_ERR_UNLIKELY));
    zassert_equal(attr->write(nullptr, attr, &byte, 1, 0, 0), BT_GATT_ERR(BT_ATT_ERR_UNLIKELY));
    zassert_equal(fixture.value->ccc.data.cfg_write(nullptr, ccc, 0), BT_GATT_ERR(BT_ATT_ERR_UNLIKELY));
    zassert_equal(bt_gatt_service_unregister(&fixture.service.definition), 0);
    fixture.service.registered = false;
    zassert_equal(attr->write(nullptr, attr, &byte, 1, 0, 0), BT_GATT_ERR(BT_ATT_ERR_UNLIKELY));
    zassert_false(bt_gatt_service_is_registered(&fixture.service.definition));
    zassert_equal(bt_gatt_service_register(&fixture.service.definition), 0);
    fixture.service.registered = true;
    zassert_true(bt_gatt_service_is_registered(&fixture.service.definition));
    zassert_true(attr->handle > 0);
  }
}

K_THREAD_STACK_DEFINE(writer_stack, 4096);
K_THREAD_STACK_DEFINE(closer_stack, 4096);
struct BlockingOwner {
  struct k_sem entered, release;
  BlockingOwner() { k_sem_init(&entered, 0, 1); k_sem_init(&release, 0, 1); }
  static void received(void* pointer) {
    auto self = static_cast<BlockingOwner*>(pointer);
    k_sem_give(&self->entered);
    zassert_equal(k_sem_take(&self->release, K_SECONDS(1)), 0);
  }
};
struct ConcurrentAccess {
  BleLocalAttribute* value;
  struct k_sem writer_done, closed, close_started;
  explicit ConcurrentAccess(BleLocalAttribute* value) : value(value) {
    k_sem_init(&writer_done, 0, 1);
    k_sem_init(&closed, 0, 1);
    k_sem_init(&close_started, 0, 1);
  }
  static void write(void* arg, void*, void*) {
    auto self = static_cast<ConcurrentAccess*>(arg);
    uint8_t byte = 42;
    auto attr = self->value->deployed;
    zassert_equal(attr->write(nullptr, attr, &byte, 1, 0, 0), 1);
    k_sem_give(&self->writer_done);
  }
  static void close(void* arg, void*, void*) {
    auto self = static_cast<ConcurrentAccess*>(arg);
    k_sem_give(&self->close_started);
    CallbackLock lock;
    auto owner = static_cast<BlockingOwner*>(self->value->owner);
    self->value->owner = nullptr;
    delete owner;
    k_sem_give(&self->closed);
  }
};
ZTEST(toit_gatt, concurrent_detach_waits_for_callback) {
  for (unsigned cycle = 0; cycle < 50; ++cycle) {
    Fixture fixture;
    auto owner = new BlockingOwner;
    fixture.value->owner = owner;
    fixture.value->notify_received = BlockingOwner::received;
    fixture.deploy();
    ConcurrentAccess access(fixture.value);
    struct k_thread writer, closer;
    k_thread_create(&writer, writer_stack, K_THREAD_STACK_SIZEOF(writer_stack),
        ConcurrentAccess::write, &access, nullptr, nullptr, 10, 0, K_NO_WAIT);
    zassert_equal(k_sem_take(&owner->entered, K_SECONDS(1)), 0);
    k_thread_create(&closer, closer_stack, K_THREAD_STACK_SIZEOF(closer_stack),
        ConcurrentAccess::close, &access, nullptr, nullptr, 10, 0, K_NO_WAIT);
    zassert_equal(k_sem_take(&access.close_started, K_SECONDS(1)), 0);
    zassert_equal(k_sem_take(&access.closed, K_MSEC(1)), -EAGAIN);
    k_sem_give(&owner->release);
    zassert_equal(k_sem_take(&access.writer_done, K_SECONDS(1)), 0);
    zassert_equal(k_sem_take(&access.closed, K_SECONDS(1)), 0);
    zassert_equal(k_thread_join(&writer, K_SECONDS(1)), 0);
    zassert_equal(k_thread_join(&closer, K_SECONDS(1)), 0);
    uint8_t byte;
    auto attr = fixture.value->deployed;
    zassert_equal(attr->read(nullptr, attr, &byte, 1, 0), BT_GATT_ERR(BT_ATT_ERR_UNLIKELY));
    zassert_equal(attr->write(nullptr, attr, &byte, 1, 0, 0), BT_GATT_ERR(BT_ATT_ERR_UNLIKELY));
  }
}
