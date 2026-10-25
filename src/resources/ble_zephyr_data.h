// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace toit {
// Bluetooth attributes are at most 512 bytes. Long reads append fragments to
// owned memory, never retaining pointers into Zephyr's receive buffers.
struct BleZephyrValue {
  static constexpr size_t CAPACITY = 512;
  uint8_t bytes[CAPACITY];
  size_t length = 0;
  bool append(const void* data, size_t size) {
    if (size > CAPACITY - length || (size && !data)) return false;
    if (size) memcpy(bytes + length, data, size);
    length += size;
    return true;
  }
};

class BleZephyrNotifications {
 public:
  static constexpr unsigned CAPACITY = 8;
  bool push(const void* data, size_t length) {
    if (count_ == CAPACITY || length > BleZephyrValue::CAPACITY || (length && !data)) return false;
    auto& value = values_[(head_ + count_) % CAPACITY];
    value.length = 0;
    if (!value.append(data, length)) return false;
    ++count_;
    return true;
  }
  const BleZephyrValue* peek() const { return count_ ? &values_[head_] : nullptr; }
  void pop() { if (count_) { head_ = (head_ + 1) % CAPACITY; --count_; } }
  void clear() { head_ = count_ = 0; }
 private:
  BleZephyrValue values_[CAPACITY];
  unsigned head_ = 0, count_ = 0;
};

// Toit UUIDs use display byte order. Normalize only for comparison / requests;
// preserve the original width when returning a filtered result to the library.
struct BleZephyrUuid {
  uint8_t bytes[16] = {};
  uint8_t length = 0;
  bool set(const uint8_t* value, size_t size) {
    if (size != 2 && size != 4 && size != 16) return false;
    memcpy(bytes, value, size);
    length = size;
    return true;
  }
  void canonical(uint8_t* out) const {
    static const uint8_t base[16] = {
      0, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0x80, 0x5f, 0x9b, 0x34, 0xfb,
    };
    memcpy(out, base, 16);
    if (length == 16) memcpy(out, bytes, 16);
    else if (length == 4) memcpy(out, bytes, 4);
    else if (length == 2) memcpy(out + 2, bytes, 2);
  }
  bool equals(const BleZephyrUuid& other) const {
    uint8_t a[16], b[16];
    canonical(a);
    other.canonical(b);
    return length && other.length && memcmp(a, b, 16) == 0;
  }
  bool as16(uint16_t* result) const {
    uint8_t expanded[16];
    canonical(expanded);
    BleZephyrUuid shortened;
    shortened.set(expanded + 2, 2);
    if (!equals(shortened)) return false;
    *result = (expanded[2] << 8) | expanded[3];
    return true;
  }
};

struct BleZephyrAttribute {
  BleZephyrUuid uuid;
  uint16_t start = 0, end = 0, value = 0;
  uint8_t properties = 0;
};

// Characteristic discovery must inspect every declaration, even when filtering
// by UUID, so descriptor ranges end before the next characteristic declaration.
class BleZephyrAttributes {
 public:
  static constexpr unsigned CAPACITY = 64;
  bool push(const BleZephyrAttribute& record, bool characteristic) {
    if (count == CAPACITY || !record.uuid.length || !record.start ||
        record.start > record.end ||
        (count && record.start <= records[count - 1].start)) return false;
    if (characteristic) {
      if (record.value <= record.start || record.value > record.end) return false;
      if (count) {
        if (records[count - 1].value >= record.start) return false;
        records[count - 1].end = record.start - 1;
      }
    }
    records[count++] = record;
    return true;
  }
  BleZephyrAttribute records[CAPACITY];
  unsigned count = 0;
};

// Legacy advertising is at most 31 bytes. Validate the entire payload before
// passing any part to the controller; padding terminates the AD sequence.
inline bool ble_zephyr_valid_ad(const uint8_t* bytes, size_t length) {
  if (length > 31) return false;
  for (size_t i = 0; i < length;) {
    unsigned size = bytes[i++];
    if (size == 0) {
      while (i < length) if (bytes[i++] != 0) return false;
      return true;
    }
    if (size > length - i) return false;
    i += size;
  }
  return true;
}

inline bool ble_zephyr_limited_ad(const uint8_t* bytes, size_t length) {
  for (size_t i = 0; i < length;) {
    unsigned size = bytes[i++];
    if (size == 0 || size > length - i) return false;
    if (bytes[i] == 1 && size == 2) return (bytes[i + 1] & 1) != 0;
    i += size;
  }
  return false;
}

struct BleZephyrReport {
  uint8_t address[7];  // Address type, then six bytes in Toit display order.
  int8_t rssi;
  bool connectable, scan_response;
  uint8_t length;
  uint8_t data[31];
};

// Callback-side storage is bounded and does not consume the HCI buffer pool.
// The caller serializes access. Full queues are reported to Toit as an error.
class BleZephyrReports {
 public:
  static constexpr unsigned CAPACITY = 16;
  void clear() { head_ = count_ = 0; }
  bool push(const BleZephyrReport& report) {
    if (count_ == CAPACITY) return false;
    reports_[(head_ + count_) % CAPACITY] = report;
    ++count_;
    return true;
  }
  const BleZephyrReport* peek() const { return count_ ? &reports_[head_] : nullptr; }
  void pop() {
    if (count_) { head_ = (head_ + 1) % CAPACITY; --count_; }
  }
 private:
  BleZephyrReport reports_[CAPACITY];
  unsigned head_ = 0, count_ = 0;
};
}  // namespace toit
