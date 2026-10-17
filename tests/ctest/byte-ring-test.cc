// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <deque>
#include <stdlib.h>
#include <thread>

#include "../../src/byte_ring.h"

namespace toit {

static void check(bool condition, int line) {
  if (!condition) FATAL("Byte ring test failed at line %d", line);
}

#define CHECK(condition) check(condition, __LINE__)

static void test_basic() {
  uint8 buffer[8];
  ByteRing ring(buffer, 8);
  CHECK(ring.capacity() == 8);
  CHECK(ring.available() == 0);
  CHECK(ring.free_space() == 8);

  uint8 out[16];
  CHECK(ring.pop(out, 16) == 0);
  CHECK(ring.push(reinterpret_cast<const uint8*>("abc"), 3) == 3);
  CHECK(ring.available() == 3);
  CHECK(ring.free_space() == 5);
  CHECK(ring.pop(out, 2) == 2);
  CHECK(memcmp(out, "ab", 2) == 0);
  CHECK(ring.pop(out, 16) == 1);
  CHECK(out[0] == 'c');
  CHECK(ring.available() == 0);
  CHECK(ring.push(out, 0) == 0);
  CHECK(ring.pop(out, 0) == 0);
}

static void test_full_and_wrap() {
  uint8 buffer[5];
  ByteRing ring(buffer, 5);
  uint8 out[8];
  // Fills exactly, with no slot kept empty.
  CHECK(ring.push(reinterpret_cast<const uint8*>("01234"), 5) == 5);
  CHECK(ring.available() == 5);
  CHECK(ring.free_space() == 0);
  CHECK(ring.push(reinterpret_cast<const uint8*>("x"), 1) == 0);
  CHECK(ring.pop(out, 3) == 3);
  CHECK(memcmp(out, "012", 3) == 0);
  // Partial push that wraps around the end of the buffer.
  CHECK(ring.push(reinterpret_cast<const uint8*>("abcdef"), 6) == 3);
  CHECK(ring.free_space() == 0);
  // Pop that wraps.
  CHECK(ring.pop(out, 8) == 5);
  CHECK(memcmp(out, "34abc", 5) == 0);
  CHECK(ring.available() == 0);
  CHECK(ring.free_space() == 5);
}

static void test_capacity_one() {
  uint8 buffer[1];
  ByteRing ring(buffer, 1);
  for (int i = 0; i < 10; i++) {
    uint8 value = i;
    CHECK(ring.push(&value, 1) == 1);
    CHECK(ring.push(&value, 1) == 0);
    uint8 out = 0xff;
    CHECK(ring.pop(&out, 4) == 1);
    CHECK(out == i);
    CHECK(ring.available() == 0);
  }
}

static void test_init_resets() {
  uint8 buffer[4];
  ByteRing ring(buffer, 4);
  CHECK(ring.push(reinterpret_cast<const uint8*>("abc"), 3) == 3);
  uint8 other[6];
  ring.init(other, 6);
  CHECK(ring.capacity() == 6);
  CHECK(ring.available() == 0);
  CHECK(ring.free_space() == 6);
}

// Random pushes and pops against a deque, over odd and even capacities,
// many times around the index range.
static void test_random() {
  srand(42);
  for (word capacity = 1; capacity <= 17; capacity++) {
    uint8* buffer = static_cast<uint8*>(malloc(capacity));
    ByteRing ring(buffer, capacity);
    std::deque<uint8> model;
    uint8 next = 0;
    for (int step = 0; step < 20000; step++) {
      uint8 data[32];
      word n = rand() % 24;
      if (rand() % 2 == 0) {
        for (word i = 0; i < n; i++) data[i] = next + i;
        word pushed = ring.push(data, n);
        CHECK(pushed == std::min<word>(n, capacity - static_cast<word>(model.size())));
        for (word i = 0; i < pushed; i++) model.push_back(next++);
      } else {
        word popped = ring.pop(data, n);
        CHECK(popped == std::min<word>(n, static_cast<word>(model.size())));
        for (word i = 0; i < popped; i++) {
          CHECK(data[i] == model.front());
          model.pop_front();
        }
      }
      CHECK(ring.available() == static_cast<word>(model.size()));
      CHECK(ring.free_space() == capacity - static_cast<word>(model.size()));
    }
    free(buffer);
  }
}

// One producer thread, one consumer thread, checking that the byte
// sequence arrives intact.
static void test_threads() {
  const word capacity = 61;
  const word total = 10000000;
  uint8 buffer[capacity];
  ByteRing ring(buffer, capacity);

  std::thread producer([&] {
    word sent = 0;
    uint32 seed = 1;
    while (sent < total) {
      uint8 data[40];
      seed = seed * 1103515245 + 12345;
      word n = std::min<word>((seed >> 16) % 40 + 1, total - sent);
      for (word i = 0; i < n; i++) data[i] = (sent + i) * 7;
      word pushed = ring.push(data, n);
      if (pushed == 0) std::this_thread::yield();
      sent += pushed;
    }
  });

  word received = 0;
  uint32 seed = 2;
  while (received < total) {
    uint8 data[40];
    seed = seed * 1103515245 + 12345;
    word popped = ring.pop(data, (seed >> 16) % 40 + 1);
    for (word i = 0; i < popped; i++) {
      CHECK(data[i] == static_cast<uint8>((received + i) * 7));
    }
    if (popped == 0) std::this_thread::yield();
    received += popped;
  }
  producer.join();
  CHECK(ring.available() == 0);
}

} // namespace toit

int main(int argc, char** argv) {
  // std::deque and std::thread allocate.
  toit::AllowThrowingNew allow;
  toit::test_basic();
  toit::test_full_and_wrap();
  toit::test_capacity_one();
  toit::test_init_resets();
  toit::test_random();
  toit::test_threads();
  return 0;
}
