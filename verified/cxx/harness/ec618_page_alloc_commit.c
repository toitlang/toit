// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
intptr_t nondet_word(void);
bool nondet_bool(void);

static cmpct_heap_t* heap;
static unsigned count, selected, probe, base, alignment, scans, fills, clears;
static intptr_t requested;
static void* tag;
static bool for_malloc;

static size_t first_free_page_run(Page*, size_t, size_t, uintptr_t, uintptr_t);
static void fill_page_statuses(Page*, size_t, uint32_t);
static void clear_words(int*, size_t);
#define IRAM_ATTR
#include "page_alloc_commit.inc"

// VeriFast proves the selection result for a stable readable status table.
static size_t first_free_page_run(Page* table, size_t length, size_t needed, uintptr_t address, uintptr_t mask) {
  __CPROVER_assert(table == heap->pages && length == count && address == base && mask == alignment - 1 &&
                   requested > 0 && needed == (size_t)requested && !scans,
                   "search the registered arena with the requested size and alignment");
  ++scans;
  return selected;
}

// Model the effect of the proved fill on an arbitrary observed entry. The
// neighbors read for accounting lie outside this exact interval.
static void fill_page_statuses(Page* start, size_t length, uint32_t value) {
  __CPROVER_assert(selected != SIZE_MAX && scans == 1 && !fills &&
                   start == &heap->pages[selected + 1] && length == (size_t)requested - 1 && value == PAGE_CONTINUED,
                   "mark precisely the remainder of the selected run");
  __CPROVER_assert(heap->pages[selected].status == (for_malloc ? PAGE_IN_USE_FOR_MALLOCS : PAGE_IN_USE) &&
                   heap->pages[selected].tag == tag, "publish the head and tag before the continuations");
  if (selected < probe && probe < selected + (size_t)requested) heap->pages[probe].status = value;
  ++fills;
}

static void clear_words(int* start, size_t words) {
  __CPROVER_assert(fills == 1 && !clears && (uintptr_t)start == base + selected * PAGE_SIZE &&
                   (uint64_t)words * sizeof(int) == (uint64_t)requested * PAGE_SIZE,
                   "clear the selected extent after marking its descriptors");
  ++clears;
}

int main(void) {
  count = nondet_uint();
  base = nondet_uint();
  __CPROVER_assume(count <= INT32_MAX / PAGE_SIZE && base != 0 && base % PAGE_SIZE == 0 &&
                   base + (uint64_t)count * PAGE_SIZE <= UINT32_MAX);
  heap = malloc(sizeof(*heap) + (count + 1) * sizeof(Page));
  __CPROVER_assume(heap != NULL);
  heap->number_of_pages = count;
  heap->page_base = (char*)base;
  requested = nondet_word();
  alignment = 1u << (nondet_uint() % 32);
  tag = (void*)(uintptr_t)nondet_uint();
  for_malloc = nondet_bool();
  bool success = requested > 0 && nondet_bool();
  selected = SIZE_MAX;
  unsigned end = 0, charge = 0;
  bool before = false, after = false;
  probe = nondet_uint();
  __CPROVER_assume(probe <= count);
  heap->pages[probe].status = nondet_uint() % 4;
  heap->pages[count].status = PAGE_IN_USE;
  if (success) {
    selected = nondet_uint();
    __CPROVER_assume(selected < count && (size_t)requested <= count - selected &&
                     (base + selected * PAGE_SIZE) % alignment == 0);
    end = selected + requested;
    charge = (size_t)requested * PAGE_SIZE;
    if (selected <= probe && probe < end) heap->pages[probe].status = PAGE_FREE;
    if (selected > 0) {
      heap->pages[selected - 1].status = nondet_uint() % 4;
      before = heap->pages[selected - 1].status == PAGE_FREE;
    }
    if (end < count) heap->pages[end].status = nondet_uint() % 4;
    after = heap->pages[end].status == PAGE_FREE;
  }
  unsigned saved_status = heap->pages[probe].status;
  void* saved_tag = heap->pages[probe].tag = (void*)(uintptr_t)nondet_uint();
  unsigned other_bytes = nondet_uint(), other_runs = nondet_uint();
  __CPROVER_assume(other_bytes <= UINT32_MAX - charge && other_runs <= UINT32_MAX - 2);
  heap->remaining = other_bytes + charge;
  heap->free_blocks = other_runs + success;

  void* result = page_alloc(heap, requested, alignment, tag, for_malloc);
  __CPROVER_assert(result == (success ? (void*)(base + selected * PAGE_SIZE) : NULL) &&
                   scans == (unsigned)(requested > 0) && fills == success && clears == success,
                   "return the cleared allocation exactly on search success");
  bool head = success && probe == selected;
  unsigned expected = head ? (for_malloc ? PAGE_IN_USE_FOR_MALLOCS : PAGE_IN_USE) :
                      success && selected < probe && probe < end ? PAGE_CONTINUED : saved_status;
  __CPROVER_assert(heap->pages[probe].status == expected && heap->pages[probe].tag == (head ? tag : saved_tag),
                   "preserve unrelated statuses, the sentinel and every non-head tag");
  __CPROVER_assert(heap->remaining == other_bytes && heap->free_blocks == other_runs + before + after,
                   "charge the selected bytes and retain each adjacent free fragment exactly once");
}
