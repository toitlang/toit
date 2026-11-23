// Copyright (C) 2026 Toit contributors.
#include "prelude.h"
#include "event_sources/i2s_mailbox_ec618.h"
#include <pthread.h>

static toit::CompletionEventMailbox<10> mailbox;
static uint32_t generation;
static unsigned slot;

static void* publish(void*) {
  mailbox.publish(slot, generation);
  return nullptr;
}

int main() {
  slot = nondet_uint();
  CXXV_ASSUME(slot < 10 && slot != 2);
  generation = nondet_uint();
  uint32_t previous = nondet_uint();
  bool pending = nondet_bool();
  if (pending) mailbox.publish(slot, previous);

  pthread_t producer;
  int started = pthread_create(&producer, nullptr, publish, nullptr);
  CXXV_ASSUME(started == 0);
  uint32_t first = 0;
  bool taken = mailbox.take(slot, &first);
  int joined = pthread_join(producer, nullptr);
  CXXV_ASSUME(joined == 0);
  uint32_t last = 0;
  bool again = mailbox.take(slot, &last);
  CXXV_ASSERT(!taken || first == generation || (pending && first == previous),
              "a racing take delivers a published generation");
  CXXV_ASSERT(again ? last == generation : taken && first == generation,
              "the final generation survives a racing take");
  CXXV_ASSERT(!mailbox.take(slot, &last), "no stale pending bit after final drain");
}
