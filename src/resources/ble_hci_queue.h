// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only. See LICENSE in the repository root.

#pragma once

#include <atomic>
#include <stdint.h>
#include <string.h>

namespace toit {
namespace ble_hci {

enum class QueueFault { none, invalid_packet, oversized_packet, overflow };
enum class QueuePush { accepted, scan_dropped, failed };
enum class QueueReceive { ready, empty, allocation_failed, failed };

// One callback producer and one VM consumer. Neither side blocks the other or
// allocates native memory. Destroy only after both sides have stopped. Reserved
// slots prevent lossy advertising reports from occupying the entire queue.
template <unsigned Capacity, unsigned MaxPacket, unsigned Reserved = 2>
class PacketQueue {
 public:
  static_assert(Capacity > Reserved && Capacity < 0x80000000u, "Invalid capacity");
  static_assert((Capacity & (Capacity - 1)) == 0, "Capacity must divide counter wraparound");
  static_assert(MaxPacket >= 5 && MaxPacket <= 65535, "Invalid packet bound");
  static_assert(ATOMIC_INT_LOCK_FREE == 2, "Callback counters must be lock-free");

  QueuePush push(const uint8_t* bytes, unsigned length) {
    if (fault() != QueueFault::none) return QueuePush::failed;
    if (length > MaxPacket) return fail(QueueFault::oversized_packet);
    if (!bytes || length < 3) return fail(QueueFault::invalid_packet);
    bool event = bytes[0] == 4 && length == 3u + bytes[2];
    bool acl = bytes[0] == 2 && length >= 5 &&
        length == 5u + bytes[3] + (static_cast<unsigned>(bytes[4]) << 8);
    if (!event && !acl) return fail(QueueFault::invalid_packet);
    bool scan = event && length >= 4 && bytes[1] == 0x3e &&
        (bytes[3] == 2 || bytes[3] == 0x0d);
    unsigned tail = tail_.load(std::memory_order_relaxed);
    unsigned count = tail - head_.load(std::memory_order_acquire);
    if (scan && count >= Capacity - Reserved) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return QueuePush::scan_dropped;
    }
    if (count == Capacity) return fail(QueueFault::overflow);
    Slot& slot = slots_[tail % Capacity];
    memcpy(slot.bytes, bytes, length);
    slot.length = length;
    if (count + 1 > high_water_.load(std::memory_order_relaxed)) {
      high_water_.store(count + 1, std::memory_order_relaxed);
    }
    tail_.store(tail + 1, std::memory_order_release);
    return QueuePush::accepted;
  }

  // Allocate before releasing the slot. Failed allocation leaves both bytes and
  // ordering unchanged. No managed pointer is retained by the queue. The producer
  // may run during allocation; it never replaces an unconsumed packet.
  template <typename Allocate>
  QueueReceive receive(Allocate allocate) {
    if (fault() != QueueFault::none) return QueueReceive::failed;
    unsigned head = head_.load(std::memory_order_relaxed);
    if (head == tail_.load(std::memory_order_acquire)) return QueueReceive::empty;
    const Slot& slot = slots_[head % Capacity];
    uint8_t* output = allocate(slot.length);
    if (!output) return QueueReceive::allocation_failed;
    if (fault() != QueueFault::none) return QueueReceive::failed;
    memcpy(output, slot.bytes, slot.length);
    head_.store(head + 1, std::memory_order_release);
    return QueueReceive::ready;
  }

  QueueFault fault() const {
    return static_cast<QueueFault>(fault_.load(std::memory_order_acquire));
  }
  unsigned scan_drops() const { return dropped_.load(std::memory_order_relaxed); }
  // Call from the consumer. The producer cannot pass the fixed consumer head.
  unsigned queued() const {
    unsigned head = head_.load(std::memory_order_relaxed);
    return tail_.load(std::memory_order_acquire) - head;
  }
  // Conservative peak: the consumer may release a slot during a producer push.
  unsigned high_water() const { return high_water_.load(std::memory_order_relaxed); }

 private:
  QueuePush fail(QueueFault fault) {
    fault_.store(static_cast<unsigned>(fault), std::memory_order_release);
    return QueuePush::failed;
  }
  struct Slot {
    uint8_t bytes[MaxPacket];
    unsigned length;
  };
  Slot slots_[Capacity];
  std::atomic<unsigned> head_{0};
  std::atomic<unsigned> tail_{0};
  std::atomic<unsigned> dropped_{0};
  std::atomic<unsigned> high_water_{0};
  std::atomic<unsigned> fault_{0};
};

} // namespace ble_hci
} // namespace toit
