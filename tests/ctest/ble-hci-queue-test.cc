// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/top.h"
#include "../../src/resources/ble_hci_queue.h"
#ifdef TOIT_LINUX
#include <pthread.h>
#include <sched.h>
#endif

using namespace toit::ble_hci;

static void check(bool condition) { if (!condition) FATAL("HCI queue check failed"); }

static void concurrent_packets(bool retry_allocations) {
#ifdef TOIT_LINUX
  PacketQueue<8, 32> queue;
  std::atomic<unsigned> consumed{0};
  const unsigned count = 100000;
  struct Context { PacketQueue<8, 32>* queue; std::atomic<unsigned>* consumed; unsigned count; };
  Context context{&queue, &consumed, count};
  pthread_t producer;
  check(pthread_create(&producer, nullptr, [](void* opaque) -> void* {
    Context& context = *static_cast<Context*>(opaque);
    uint8_t packet[] = {2, 1, 0, 4, 0, 0, 0, 0, 0};
    for (unsigned sequence = 0; sequence < context.count; sequence++) {
      // Keep this test below overflow while repeatedly wrapping queue slots.
      while (sequence - context.consumed->load(std::memory_order_acquire) >= 4) sched_yield();
      memcpy(packet + 5, &sequence, sizeof(sequence));
      check(context.queue->push(packet, sizeof(packet)) == QueuePush::accepted);
      memset(packet + 5, 0xff, 4);
    }
    return nullptr;
  }, &context) == 0);
  unsigned allocations = 0;
  unsigned failures = 0;
  for (unsigned sequence = 0; sequence < count;) {
    uint8_t owned[9];
    memset(owned, 0xcc, sizeof(owned));
    auto status = queue.receive([&](unsigned size) -> uint8_t* {
      check(size == sizeof(owned));
      allocations++;
      if (retry_allocations && allocations % 2 == 1) return nullptr;
      return owned;
    });
    if (status == QueueReceive::empty) {
      sched_yield();
      continue;
    }
    if (status == QueueReceive::allocation_failed) {
      check(retry_allocations);
      for (auto byte : owned) check(byte == 0xcc);
      failures++;
      sched_yield();
      continue;
    }
    check(status == QueueReceive::ready);
    unsigned actual;
    memcpy(&actual, owned + 5, sizeof(actual));
    check(actual == sequence);
    consumed.store(++sequence, std::memory_order_release);
  }
  check(pthread_join(producer, nullptr) == 0);
  check(failures == (retry_allocations ? count : 0));
  check(queue.queued() == 0 && queue.fault() == QueueFault::none);
#endif
}

int main(int argc, char** argv) {
  PacketQueue<4, 32> queue;
  uint8_t first[] = {4, 14, 1, 7};
  uint8_t second[] = {2, 1, 0, 1, 0, 9};
  uint8_t output[32];
  unsigned length = 0;
  auto allocate = [&](unsigned size) { length = size; return output; };
  check(queue.queued() == 0 && queue.high_water() == 0);
  check(queue.receive(allocate) == QueueReceive::empty);
  check(queue.push(first, sizeof(first)) == QueuePush::accepted);
  first[3] = 99;
  for (int i = 0; i < 3; i++) {
    check(queue.receive([](unsigned size) -> uint8_t* {
      check(size == 4);
      return nullptr;
    }) == QueueReceive::allocation_failed);
    check(queue.queued() == 1 && queue.high_water() == 1);
  }
  // Simulate an arrival while the VM allocates, before the first slot is freed.
  check(queue.receive([&](unsigned size) {
    check(queue.push(second, sizeof(second)) == QueuePush::accepted);
    return allocate(size);
  }) == QueueReceive::ready);
  check(length == 4 && output[3] == 7);
  check(queue.receive(allocate) == QueueReceive::ready);
  check(length == 6 && output[5] == 9);
  check(queue.queued() == 0 && queue.high_water() == 2);
  for (int i = 0; i < 1000; i++) {
    check(queue.push(first, sizeof(first)) == QueuePush::accepted);
    check(queue.receive(allocate) == QueueReceive::ready);
  }
  uint8_t scan[] = {4, 0x3e, 1, 2};
  check(queue.push(scan, sizeof(scan)) == QueuePush::accepted);
  check(queue.push(scan, sizeof(scan)) == QueuePush::accepted);
  check(queue.push(scan, sizeof(scan)) == QueuePush::scan_dropped);
  check(queue.scan_drops() == 1);
  check(queue.queued() == 2 && queue.high_water() == 2);
  check(queue.push(first, sizeof(first)) == QueuePush::accepted);
  check(queue.push(second, sizeof(second)) == QueuePush::accepted);
  check(queue.push(first, sizeof(first)) == QueuePush::failed);
  check(queue.fault() == QueueFault::overflow);
  check(queue.queued() == 4 && queue.high_water() == 4 && queue.scan_drops() == 1);
  check(queue.receive(allocate) == QueueReceive::failed);
  check(queue.push(scan, sizeof(scan)) == QueuePush::failed);

  PacketQueue<4, 32> malformed;
  check(malformed.push(second, sizeof(second) - 1) == QueuePush::failed);
  check(malformed.fault() == QueueFault::invalid_packet);
  PacketQueue<4, 32> oversized;
  uint8_t large[33] = {};
  check(oversized.push(large, sizeof(large)) == QueuePush::failed);
  check(oversized.fault() == QueueFault::oversized_packet);
  PacketQueue<4, 32> interrupted;
  check(interrupted.push(first, sizeof(first)) == QueuePush::accepted);
  memset(output, 0xcc, sizeof(output));
  check(interrupted.receive([&](unsigned size) {
    for (int i = 0; i < 3; i++) check(interrupted.push(first, sizeof(first)) == QueuePush::accepted);
    check(interrupted.push(first, sizeof(first)) == QueuePush::failed);
    return output;
  }) == QueueReceive::failed);
  check(output[0] == 0xcc);
  concurrent_packets(false);
  concurrent_packets(true);
  return 0;
}
