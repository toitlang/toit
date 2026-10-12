// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

#include <atomic>
#include <chrono>
#include <stdio.h>
#include <stdlib.h>
#include <thread>

#include "../../src/top.h"
#include "../../src/event_sources/i2s_mailbox_ec618.h"
#include "../../src/resources/i2s_state_ec618.h"

using toit::I2sEventMailbox;
using toit::I2sRunState;

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #condition); \
    exit(1); \
  } \
} while (0)

static void test_fault_and_recovery() {
  I2sRunState run;
  I2sEventMailbox mailbox;
  uint32_t generation;
  CHECK(!run.start(1));
  CHECK(!run.stop());
  CHECK(!run.start(1));  // Stop must not configure an unopened stream.
  CHECK(run.configure());
  CHECK(run.start(2));
  CHECK(!run.configure());
  CHECK(!run.start(3));
  CHECK(run.generation() == 2);

  // A completion is queued, then a fatal bus error occurs before dispatch.
  CHECK(mailbox.publish(0, 2));
  CHECK(run.fail());
  CHECK(!mailbox.publish(0, 2));
  CHECK(mailbox.take(0, &generation));
  CHECK(run.accepts(generation));
  CHECK(run.failed());  // The coalesced completion must expose the fault.
  CHECK(!run.fail());
  CHECK(!run.start(3));
  CHECK(!run.configure());
  CHECK(run.failed());  // Reading the error must not clear it for other waiters.

  CHECK(mailbox.publish(0, 2));
  CHECK(run.stop());
  CHECK(!run.stop());
  CHECK(!run.accepts(2));
  CHECK(run.start(4));
  CHECK(!run.failed());
  CHECK(mailbox.take(0, &generation));
  CHECK(!run.accepts(generation));  // Old queued fault after stop/restart.
  CHECK(mailbox.publish(0, 4));
  CHECK(mailbox.take(0, &generation));
  CHECK(run.accepts(generation));
  CHECK(!run.failed());
}

static void test_full_queue_and_replacement() {
  I2sEventMailbox mailbox;
  uint32_t generation;
  CHECK(mailbox.publish(0, 100));
  // Deliberately drop the wake-up token, as when the shared queue is full.
  // Consuming any existing queued event drains the still-pending mailbox.
  CHECK(mailbox.publish(1, 200));
  CHECK(!mailbox.publish(0, 101));
  CHECK(mailbox.take(0, &generation));
  CHECK(generation == 101);  // Latest resource generation survives coalescing.
  CHECK(mailbox.take(1, &generation));
  CHECK(generation == 200);
  CHECK(!mailbox.take(0, &generation));
  CHECK(!mailbox.take(1, &generation));
  CHECK(mailbox.publish(0, 102));  // A publish after drain needs a new wake-up.
  CHECK(mailbox.take(0, &generation));
  CHECK(generation == 102);
}

static void test_publish_during_drain() {
  I2sEventMailbox mailbox;
  std::atomic<bool> done{false};
  const uint32_t last = 100000;
  std::thread producer([&] {
    for (uint32_t generation = 1; generation <= last; generation++) {
      mailbox.publish(0, generation);
      mailbox.publish(1, generation);
    }
    done.store(true, std::memory_order_release);
  });
  uint32_t seen[2] = {};
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (!done.load(std::memory_order_acquire) || seen[0] != last || seen[1] != last) {
    for (unsigned id = 0; id < 2; id++) {
      uint32_t generation;
      if (mailbox.take(id, &generation)) {
        CHECK(generation >= seen[id]);
        seen[id] = generation;
      }
    }
    CHECK(std::chrono::steady_clock::now() < deadline);
  }
  producer.join();
}

int main() {
  toit::AllowThrowingNew allow;
  test_fault_and_recovery();
  test_full_queue_and_replacement();
  test_publish_during_drain();
  puts("EC618 I2S fault state and notification delivery PASS");
}
