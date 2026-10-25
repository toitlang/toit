// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include "../../../src/resources/ble_zephyr_data.h"
#include <assert.h>
#include <stdio.h>
using namespace toit;

int main() {
  BleZephyrNotifications notifications;
  assert(!notifications.peek());
  assert(!notifications.push(nullptr, 1));
  uint8_t payload[512];
  assert(!notifications.push(payload, sizeof(payload) + 1));
  assert(!notifications.push(payload, SIZE_MAX));
  for (unsigned round = 0; round < 100; ++round) {
    for (unsigned i = 0; i < BleZephyrNotifications::CAPACITY; ++i) {
      memset(payload, i, sizeof(payload));
      assert(notifications.push(payload, sizeof(payload)));
    }
    assert(!notifications.push(nullptr, 0));
    memset(payload, 0xff, sizeof(payload));
    for (unsigned i = 0; i < BleZephyrNotifications::CAPACITY; ++i) {
      assert(notifications.peek()->length == sizeof(payload));
      for (auto byte : notifications.peek()->bytes) assert(byte == i);
      notifications.pop();
    }
    assert(!notifications.peek());
    assert(notifications.push(nullptr, 0));
    assert(notifications.peek()->length == 0);
    notifications.pop();  // Advance the ring head to exercise wraparound.
  }
  assert(notifications.push(payload, sizeof(payload)));
  notifications.clear();
  assert(!notifications.peek());
  assert(notifications.push(nullptr, 0));
  assert(notifications.peek()->length == 0);
  // Assemble a maximum-size long read at every possible fragment size. The
  // temporary fragments are overwritten immediately to check independent
  // ownership, and overflow must preserve the complete result.
  for (size_t fragment = 1; fragment <= BleZephyrValue::CAPACITY; ++fragment) {
    BleZephyrValue value;
    assert(value.append(nullptr, 0));
    assert(!value.append(nullptr, 1));
    while (value.length < BleZephyrValue::CAPACITY) {
      size_t offset = value.length;
      size_t size = fragment;
      if (size > BleZephyrValue::CAPACITY - offset) size = BleZephyrValue::CAPACITY - offset;
      auto bytes = new uint8_t[size];
      for (size_t i = 0; i < size; ++i) bytes[i] = (offset + i) & 0xff;
      assert(value.append(bytes, size));
      memset(bytes, 0, size);
      delete[] bytes;
    }
    uint8_t extra = 0;
    assert(!value.append(&extra, 1));
    assert(!value.append(&extra, SIZE_MAX));
    assert(value.length == BleZephyrValue::CAPACITY);
    for (size_t i = 0; i < value.length; ++i) assert(value.bytes[i] == (i & 0xff));
  }
  BleZephyrUuid short_uuid, long_uuid, wide_uuid, invalid;
  const uint8_t heart_rate[] = {0x18, 0x0d};
  const uint8_t heart_rate_32[] = {0, 0, 0x18, 0x0d};
  const uint8_t heart_rate_128[] = {
    0, 0, 0x18, 0x0d, 0, 0, 0x10, 0, 0x80, 0, 0, 0x80, 0x5f, 0x9b, 0x34, 0xfb,
  };
  assert(short_uuid.set(heart_rate, 2));
  assert(wide_uuid.set(heart_rate_32, 4));
  assert(long_uuid.set(heart_rate_128, 16));
  assert(short_uuid.equals(long_uuid));
  assert(wide_uuid.equals(short_uuid));
  assert(!short_uuid.equals(invalid));
  uint16_t compact = 0;
  assert(short_uuid.as16(&compact) && compact == 0x180d);
  assert(wide_uuid.as16(&compact) && compact == 0x180d);
  assert(long_uuid.as16(&compact) && compact == 0x180d);
  assert(!invalid.as16(&compact));
  wide_uuid.bytes[0] = 1;
  assert(!wide_uuid.as16(&compact));
  for (unsigned size = 0; size < 20; ++size) {
    uint8_t bytes[20] = {};
    assert(invalid.set(bytes, size) == (size == 2 || size == 4 || size == 16));
  }
  long_uuid.bytes[15] ^= 1;
  assert(!short_uuid.equals(long_uuid));
  assert(!long_uuid.as16(&compact));

  BleZephyrAttributes attributes;
  BleZephyrAttribute attribute;
  attribute.uuid = short_uuid;
  attribute.start = 2;
  attribute.value = 3;
  attribute.end = 100;
  assert(attributes.push(attribute, true));
  attribute.start = 10;
  attribute.value = 11;
  assert(attributes.push(attribute, true));
  // A filtered first characteristic's descriptors stop at 9, before the next
  // declaration at 10, even if that second characteristic isn't returned.
  assert(attributes.records[0].end == 9);
  assert(attributes.records[1].end == 100);
  attribute.start = 11;
  attribute.value = 12;
  assert(!attributes.push(attribute, true));  // Overlaps previous value.
  assert(attributes.records[1].end == 100);  // Failed input must not alter range.
  attribute.start = 12;
  attribute.value = 101;
  assert(!attributes.push(attribute, true));
  attribute.value = 12;
  assert(!attributes.push(attribute, true));  // Declaration is not its value.
  attribute.start = 0;
  assert(!attributes.push(attribute, false));
  attributes.count = 0;
  attribute.end = UINT16_MAX;
  for (unsigned i = 0; i < BleZephyrAttributes::CAPACITY; ++i) {
    attribute.start = 2 * i + 1;
    attribute.value = attribute.start + 1;
    assert(attributes.push(attribute, true));
  }
  attribute.start += 2;
  attribute.value += 2;
  assert(!attributes.push(attribute, true));
  assert(attributes.records[BleZephyrAttributes::CAPACITY - 1].end == UINT16_MAX);
  attributes.count = 0;
  attribute.start = UINT16_MAX - 1;
  attribute.value = UINT16_MAX;
  assert(attributes.push(attribute, true));
  assert(attributes.records[0].value == attributes.records[0].end);

  const uint8_t limited[] = {2, 1, 1, 3, 9, 'o', 'k'};
  const uint8_t general[] = {2, 1, 2};
  const uint8_t truncated[] = {4, 9, 'x'};
  const uint8_t bad_padding[] = {0, 1};
  assert(ble_zephyr_valid_ad(nullptr, 0));
  assert(ble_zephyr_valid_ad(limited, sizeof(limited)));
  assert(ble_zephyr_limited_ad(limited, sizeof(limited)));
  assert(!ble_zephyr_limited_ad(general, sizeof(general)));
  assert(!ble_zephyr_valid_ad(truncated, sizeof(truncated)));
  assert(!ble_zephyr_valid_ad(bad_padding, sizeof(bad_padding)));
  // Exhaust all leading length values at every legal legacy payload size.
  // Exact allocations let ASan detect any parser access beyond the payload.
  for (unsigned length = 1; length <= 32; ++length) {
    auto bytes = new uint8_t[length]();
    for (unsigned first = 0; first <= 255; ++first) {
      bytes[0] = first;
      bool expected = length <= 31 && first < length;
      assert(ble_zephyr_valid_ad(bytes, length) == expected);
      assert(!ble_zephyr_limited_ad(bytes, length));
    }
    delete[] bytes;
  }
  BleZephyrReports reports;
  assert(!reports.peek());
  BleZephyrReport report = {};
  for (unsigned round = 0; round < 100; ++round) {
    for (unsigned i = 0; i < BleZephyrReports::CAPACITY; ++i) {
      report.address[0] = i;
      report.rssi = -int(i);
      report.length = 31;
      memset(report.data, i, sizeof(report.data));
      assert(reports.push(report));
    }
    assert(!reports.push(report));
    memset(report.data, 0xff, sizeof(report.data));
    for (unsigned i = 0; i < BleZephyrReports::CAPACITY; ++i) {
      assert(reports.peek()->address[0] == i);
      assert(reports.peek()->rssi == -int(i));
      for (auto byte : reports.peek()->data) assert(byte == i);
      reports.pop();
    }
    assert(!reports.peek());
    // Advance the ring head by one so the next iteration wraps differently.
    assert(reports.push(report));
    reports.pop();
  }
  assert(reports.push(report));
  reports.clear();
  assert(!reports.peek());
  puts("BLE DATA PASS: notification FIFO/ownership/bounds, long reads, UUIDs, descriptor ranges, GATT capacity and advertising reports");
}
