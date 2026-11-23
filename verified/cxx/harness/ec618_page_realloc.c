// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
enum { capacity = 4 };
static _Alignas(PAGE_SIZE) unsigned char region[capacity * PAGE_SIZE];
static void *old_payload, *expected_result, *new_tag;
static size_t old_bytes;
static unsigned moves;
static void* move_payload(void* dest, const void* src, size_t bytes) {
  __CPROVER_assert(dest == expected_result && src == old_payload && bytes == old_bytes,
                   "move the complete old payload to the new head");
  ++moves;
  return dest;
}
#define memmove move_payload
#define IRAM_ATTR
#define GET_THREAD_LOCAL_TAG new_tag
#include "page_realloc.inc"

int main(void) {
  unsigned count = nondet_uint(), first = nondet_uint(), old = nondet_uint();
  __CPROVER_assume(count > 0 && count <= capacity && first < count && old > 0 && old <= count - first);
  cmpct_heap_t* heap = malloc(sizeof(*heap) + (capacity + 1) * sizeof(Page));
  __CPROVER_assume(heap != NULL);
  // Use one physical object so moving backwards stays inside the arena.
  uintptr_t base = (uintptr_t)region;
  __CPROVER_assume(base % PAGE_SIZE == 0 && base + (uint64_t)count * PAGE_SIZE <= UINT32_MAX);
  heap->page_base = (char*)region;
  heap->number_of_pages = count;
  old_payload = region + first * PAGE_SIZE;
  old_bytes = old * PAGE_SIZE;
  new_tag = (void*)(uintptr_t)nondet_uint();
  unsigned before[capacity + 1], free_count = 0, runs = 0, occupied_elsewhere = 0;
  void* tags[capacity + 1];
  for (unsigned i = 0; i <= capacity; ++i) {
    unsigned state = i == count ? PAGE_IN_USE : nondet_uint() % 4;
    if (i == first) state = PAGE_IN_USE;
    if (first < i && i < first + old) state = PAGE_CONTINUED;
    __CPROVER_assume(i != first + old || state != PAGE_CONTINUED);
    if (i < count && (i < first || i >= first + old) && state != PAGE_FREE)
      occupied_elsewhere |= 1u << i;
    before[i] = heap->pages[i].status = state;
    tags[i] = heap->pages[i].tag = (void*)(uintptr_t)nondet_uint();
    if (i < count && state == PAGE_FREE) {
      ++free_count;
      if (i == 0 || before[i - 1] != PAGE_FREE) ++runs;
    }
  }
  unsigned other_bytes = nondet_uint(), other_runs = nondet_uint();
  __CPROVER_assume(other_bytes <= UINT32_MAX - capacity * PAGE_SIZE && other_runs <= UINT32_MAX - capacity);
  heap->remaining = other_bytes + free_count * PAGE_SIZE;
  heap->free_blocks = other_runs + runs;
  unsigned request = nondet_uint();
  __CPROVER_assume(request > 0);
  uint64_t needed = ((uint64_t)request + PAGE_SIZE - 1) / PAGE_SIZE;
  // Enumerate containing intervals independently. Prefer the latest possible
  // start so the old payload stays in place whenever forward growth fits.
  int selected = -1;
  if (needed <= old) selected = first;
  else if (needed <= count) {
    for (unsigned start = 0; start <= first; ++start) {
      if (start + needed > count || start + needed < first + old) continue;
      unsigned mask = ((1u << (unsigned)needed) - 1u) << start;
      if ((occupied_elsewhere & mask) == 0) selected = start;
    }
  }
  expected_result = selected < 0 ? NULL : region + (unsigned)selected * PAGE_SIZE;
  void* result = realloc_page_allocation(heap, old_payload, request, old_bytes);
  __CPROVER_assert(result == expected_result && moves == (unsigned)(selected >= 0 && (unsigned)selected != first),
                   "return the preferred fitting interval and copy only for a move");
  runs = free_count = 0;
  bool previous_free = false;
  for (unsigned i = 0; i <= capacity; ++i) {
    unsigned state = before[i];
    bool head = selected >= 0 && i == (unsigned)selected;
    if (selected >= 0) {
      if (first <= i && i < first + old) state = PAGE_FREE;
      if (head) state = PAGE_IN_USE;
      else if ((unsigned)selected < i && i < (unsigned)selected + needed) state = PAGE_CONTINUED;
    }
    __CPROVER_assert(heap->pages[i].status == state && heap->pages[i].tag == (head ? new_tag : tags[i]),
                     "retag the resulting head and preserve all other tags and unaffected statuses");
    if (i < count && state == PAGE_FREE) {
      ++free_count;
      if (!previous_free) ++runs;
    }
    previous_free = state == PAGE_FREE;
  }
  __CPROVER_assert(heap->remaining == other_bytes + free_count * PAGE_SIZE && heap->free_blocks == other_runs + runs,
                   "account for exactly the free bytes and contiguous runs after resizing");
}
