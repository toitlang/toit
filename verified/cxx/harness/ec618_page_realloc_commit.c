// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
static cmpct_heap_t* heap;
static unsigned count, base, head, old, needed, selected, left, right, probe;
static unsigned scans, fills, moves;
static void* new_tag;
static size_t page_number(cmpct_heap_t*, void*);
static size_t page_growth_start(Page*, size_t, size_t, size_t, size_t);
static void fill_page_statuses(Page*, size_t, uint32_t);
static void* move_payload(void*, const void*, size_t);
#define IRAM_ATTR
#define GET_THREAD_LOCAL_TAG new_tag
#define memmove move_payload
#include "page_realloc_commit.inc"

// The page-number gate checks this conversion for every address and arena.
static size_t page_number(cmpct_heap_t* owner, void* address) {
  __CPROVER_assert(owner == heap && (uintptr_t)address == base + head * PAGE_SIZE,
                   "look up the current live direct head");
  return head;
}

// The read-only selector's VeriFast postcondition uses the contiguous free
// lengths on either side of the old run.
static size_t page_growth_start(Page* table, size_t n, size_t start, size_t current, size_t target) {
  __CPROVER_assert(table == heap->pages && n == count && start == head && current == old &&
                   target == needed && target > old && target <= count && !scans,
                   "try growth only for the complete live extent inside the registered table");
  ++scans;
  return selected;
}

static void fill_page_statuses(Page* start, size_t length, uint32_t value) {
  __CPROVER_assert(selected != SIZE_MAX && !fills, "write a single interval on a successful resize");
  if (needed > old) {
    __CPROVER_assert(start == &heap->pages[selected + 1] && length == needed - 1 && value == PAGE_CONTINUED &&
                     heap->pages[selected].status == PAGE_IN_USE, "mark the full extension behind the new direct head");
    if (selected < probe && probe < selected + needed) heap->pages[probe].status = value;
  } else {
    __CPROVER_assert(needed < old && start == &heap->pages[head + needed] && length == old - needed &&
                     value == PAGE_FREE, "release only the discarded tail when shrinking");
    if (head + needed <= probe && probe < head + old) heap->pages[probe].status = value;
  }
  ++fills;
}

static void* move_payload(void* dest, const void* src, size_t bytes) {
  __CPROVER_assert(selected < head && (uintptr_t)dest == base + selected * PAGE_SIZE &&
                   (uintptr_t)src == base + head * PAGE_SIZE && bytes == old * PAGE_SIZE && fills == 1,
                   "move exactly the old payload between the two registered addresses");
  ++moves;
  return dest;
}

// Describe an arbitrary observed descriptor consistent with the two maximal
// free neighbors. The sentinel and the old head are both in use.
static unsigned status_at(unsigned i) {
  if (i == count || i == head) return PAGE_IN_USE;
  if (head < i && i < head + old) return PAGE_CONTINUED;
  if ((head - left <= i && i < head) || (head + old <= i && i < head + old + right)) return PAGE_FREE;
  unsigned status = nondet_uint() % 4;
  if (i + 1 == head - left || i == head + old + right)
    __CPROVER_assume(status != PAGE_FREE);
  if (i == head + old) __CPROVER_assume(status != PAGE_CONTINUED);
  return status;
}

int main(void) {
  base = nondet_uint();
  count = nondet_uint();
  head = nondet_uint();
  unsigned first_free = nondet_uint(), old_end = nondet_uint(), right_limit = nondet_uint();
  __CPROVER_assume(count <= INT32_MAX / PAGE_SIZE && first_free <= head && head < old_end &&
                   old_end <= right_limit && right_limit <= count && base && base % PAGE_SIZE == 0 &&
                   base + (uint64_t)count * PAGE_SIZE <= UINT32_MAX);
  old = old_end - head;
  left = head - first_free;
  right = right_limit - old_end;
  unsigned request = nondet_uint();
  __CPROVER_assume(request > 0);
  needed = ((uint64_t)request + PAGE_SIZE - 1) / PAGE_SIZE;
  // The latest start preserving the old payload is the smaller of the old
  // head and the rightmost start that leaves room before the busy boundary.
  selected = SIZE_MAX;
  if (needed <= right_limit - first_free) {
    unsigned latest = right_limit - needed;
    selected = latest < head ? latest : head;
  }
  bool success = selected != SIZE_MAX;
  heap = malloc(sizeof(*heap) + (count + 1) * sizeof(Page));
  __CPROVER_assume(heap != NULL);
  heap->number_of_pages = count;
  heap->page_base = (char*)base;
  probe = nondet_uint();
  __CPROVER_assume(probe <= count);
  unsigned saved_status = status_at(probe);
  __CPROVER_assume(heap->pages[probe].status == saved_status);
  // Constrain the initial availability at the boundaries the update reads.
  // The rest of the table remains arbitrary, including descriptors beyond
  // the two neighboring free runs.
  __CPROVER_assume((heap->pages[old_end].status == PAGE_FREE) == (right != 0));
  if (success && needed > old) {
    if (selected < head && selected > 0)
      __CPROVER_assume((heap->pages[selected - 1].status == PAGE_FREE) == (selected > first_free));
    unsigned limit = selected + needed;
    if (limit > old_end)
      __CPROVER_assume((heap->pages[limit].status == PAGE_FREE) == (limit < right_limit));
  }
  void* saved_tag = heap->pages[probe].tag;
  new_tag = (void*)(uintptr_t)nondet_uint();
  unsigned outside_runs = nondet_uint(), outside_bytes = nondet_uint();
  __CPROVER_assume(outside_runs <= UINT32_MAX - 2 && outside_bytes <= UINT32_MAX - count * PAGE_SIZE);
  heap->free_blocks = outside_runs + (left != 0) + (right != 0);
  heap->remaining = outside_bytes + (left + right) * PAGE_SIZE;
  void* result = realloc_page_allocation(heap, (void*)(base + head * PAGE_SIZE), request, old * PAGE_SIZE);
  __CPROVER_assert(result == (success ? (void*)(base + selected * PAGE_SIZE) : NULL) &&
                   scans == (unsigned)(needed > old && needed <= count) && fills == (unsigned)(success && needed != old) &&
                   moves == (unsigned)(selected < head), "propagate failure or return the chosen extent with the required copy");
  unsigned expected = saved_status;
  if (success && selected <= probe && probe < selected + needed)
    expected = probe == selected ? PAGE_IN_USE : PAGE_CONTINUED;
  else if (success && head <= probe && probe < head + old) expected = PAGE_FREE;
  __CPROVER_assert(heap->pages[probe].status == expected && heap->pages[probe].tag ==
                   (success && selected == probe ? new_tag : saved_tag), "preserve every unrelated status and non-head tag");
  unsigned final_left = success ? selected - first_free : left;
  unsigned final_right = success ? right_limit - (selected + needed) : right;
  __CPROVER_assert(heap->free_blocks == outside_runs + (final_left != 0) + (final_right != 0) &&
                   heap->remaining == outside_bytes + (final_left + final_right) * PAGE_SIZE,
                   "account for the exact residual free extents on both sides");
}
