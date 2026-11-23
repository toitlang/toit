// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
static void* task;
static unsigned depth, entry_depth, locks, lookups;
#define taskSCHEDULER_NOT_STARTED 0
static int scheduler_state;
static int xTaskGetSchedulerState(void) { return scheduler_state; }

static void vTaskSuspendAll(void) {
  __CPROVER_assert(depth == entry_depth, "option operation nests once");
  ++depth;
  ++locks;
}
static void xTaskResumeAll(void) {
  __CPROVER_assert(depth == entry_depth + 1, "option operation releases its lock");
  --depth;
}
static void* xTaskGetCurrentTaskHandle(void) {
  __CPROVER_assert(scheduler_state == taskSCHEDULER_NOT_STARTED || depth == entry_depth + 1,
                   "sample the calling task while serialized");
  ++lookups;
  return task;
}
#include "thread_tags.inc"

int main(void) {
  cmpct_heap_t heap;
  scheduler_state = (int)nondet_uint();
  bool running = scheduler_state != taskSCHEDULER_NOT_STARTED;
  entry_depth = depth = nondet_uint();
  __CPROVER_assume(entry_depth < UINT32_MAX);
  task = (void*)(uintptr_t)nondet_uint();
  void* value = (void*)(uintptr_t)nondet_uint();
  void* old_option = heap.ignore_free = (void*)(uintptr_t)nondet_uint();
  int option = (int)nondet_uint();
  unsigned probe = nondet_uint();
  __CPROVER_assume(probe < MAX_TAG_ENTRIES);
  unsigned match = MAX_TAG_ENTRIES, empty = MAX_TAG_ENTRIES;
  void* previous = NULL;
  for (unsigned i = 0; i < MAX_TAG_ENTRIES; ++i) {
    void* owner = tag_map[i].task = (void*)(uintptr_t)nondet_uint();
    void* tag = tag_map[i].tag = (void*)(uintptr_t)nondet_uint();
    __CPROVER_assume((owner == NULL) == (tag == NULL));
    if (task && owner == task) {
      __CPROVER_assume(match == MAX_TAG_ENTRIES);
      match = i;
      previous = tag;
    }
    if (owner == NULL && empty == MAX_TAG_ENTRIES) empty = i;
  }
  void* owner_before = tag_map[probe].task;
  void* tag_before = tag_map[probe].tag;
  bool tagging = option == MALLOC_OPTION_THREAD_TAG;
  unsigned target = match < MAX_TAG_ENTRIES ? match : value ? empty : MAX_TAG_ENTRIES;
  bool changed = tagging && task && probe == target;

  __CPROVER_assert(vPortGetHeapTag() == previous, "read the original task tag");
  if (tagging) vPortSetHeapTag(value);
  else cmpct_set_option(&heap, option, value);
  __CPROVER_assert(depth == entry_depth && lookups == 1u + tagging && locks == running * lookups, "option write balances serialization");
  __CPROVER_assert(tag_map[probe].task == (changed ? (value ? task : NULL) : owner_before) &&
                   tag_map[probe].tag == (changed ? value : tag_before),
                   "change only the existing or first available slot; clear releases its owner");
  __CPROVER_assert(heap.ignore_free == (option == MALLOC_OPTION_DISABLE_FREE ? value : old_option),
                   "only the disable-free option changes its heap field");
  void* expected = tagging && task && target < MAX_TAG_ENTRIES ? value : previous;
  __CPROVER_assert(vPortGetHeapTag() == expected,
                   "subsequent lookup observes update, clear, or full-table refusal");
  __CPROVER_assert(depth == entry_depth && lookups == 2u + tagging && locks == running * lookups, "option read balances serialization");
  if (!tagging) {
    __CPROVER_assert(cmpct_get_option(option) == NULL && locks == 2u * running && lookups == 2,
                     "other options expose no thread tag");
  }
}
