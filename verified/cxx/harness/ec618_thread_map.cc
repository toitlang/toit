// Copyright (C) 2026 Toit contributors.

#include "prelude.h"

using TaskHandle_t = void*;
class Thread {};
static TaskHandle_t current_task;
static uint32_t mask, incoming;
static unsigned locks, restores;
static bool full_or_no_task, failed;

static TaskHandle_t xTaskGetCurrentTaskHandle() { return current_task; }
static uint32_t __get_PRIMASK() { return mask; }
static void __disable_irq() { mask = 1; ++locks; }
static void __DMB() { CXXV_ASSERT(mask == 1, "barrier inside masked section"); }
static void check_published_map();
static void __set_PRIMASK(uint32_t value) {
  CXXV_ASSERT(value == incoming, "restore incoming interrupt state");
  check_published_map();
  mask = value;
  ++restores;
}

#undef FATAL
#define FATAL(msg) do { CXXV_ASSERT(full_or_no_task && mask == incoming, "expected registration failure outside guard"); failed = true; return; } while (false)
#include "thread_map.inc"

static unsigned probe;
static ThreadMapEntry expected;
static ThreadMapEntry* expected_cache;
static void check_published_map() {
  CXXV_ASSERT(thread_map[probe].task == expected.task && thread_map[probe].thread == expected.thread,
              "publish complete entry before another task may observe it");
  CXXV_ASSERT(cached_thread_entry == expected_cache, "cache agrees with published map");
}

int main() {
  constexpr unsigned N = CONFIG_TOIT_EC618_MAX_THREADS;
  static int tasks[N + 1];
  static Thread threads[N], replacement;
  unsigned selected = nondet_uint(), cached = nondet_uint();
  probe = nondet_uint();
  CXXV_ASSUME(selected <= N + 1 && probe < N && cached <= N);
  current_task = selected <= N ? &tasks[selected] : nullptr;
  int existing = -1, empty = -1;
  for (unsigned i = 0; i < N; ++i) {
    // Each occupied slot has its own identity. The operation only compares
    // identities for equality; this represents any permutation of live tasks.
    if (nondet_bool()) {
      thread_map[i].task = &tasks[i];
      thread_map[i].thread = &threads[i];
      if (i == selected) existing = i;
      if (i == cached) cached_thread_entry = &thread_map[i];
    } else if (empty < 0) {
      empty = i;
    }
  }
  auto old = thread_map[probe];
  auto old_cache = cached_thread_entry;
  expected = old;
  expected_cache = old_cache;
  unsigned op = nondet_uint();
  CXXV_ASSUME(op < 3);
  incoming = mask = nondet_bool() ? 1 : 0;
  if (op == 0) {
    if (existing >= 0) expected_cache = &thread_map[existing];
    Thread* found = get_current_thread();
    CXXV_ASSERT(found == (existing < 0 ? nullptr : &threads[selected]), "lookup by current task identity");
  } else if (op == 1) {
    int slot = existing >= 0 ? existing : empty;
    full_or_no_task = current_task == nullptr || slot < 0;
    if (!full_or_no_task) {
      expected_cache = &thread_map[slot];
      if (probe == static_cast<unsigned>(slot)) expected = {current_task, &replacement};
    }
    set_current_thread(&replacement);
    CXXV_ASSERT(failed == full_or_no_task, "reject exactly missing task or full map with no matching task");
  } else {
    if (existing >= 0) {
      if (expected_cache == &thread_map[existing]) expected_cache = nullptr;
      if (probe == static_cast<unsigned>(existing)) expected = {nullptr, nullptr};
    }
    clear_current_thread();
  }
  CXXV_ASSERT(mask == incoming && locks == restores &&
              locks == (op == 1 && !current_task ? 0u : 1u), "one balanced masked transaction");
  CXXV_ASSERT(thread_map[probe].task == expected.task && thread_map[probe].thread == expected.thread,
              "change only the selected map entry");
  CXXV_ASSERT(cached_thread_entry == expected_cache, "publish or invalidate the matching cached entry");
}
