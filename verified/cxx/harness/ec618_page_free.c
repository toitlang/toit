// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
bool nondet_bool(void);

enum { capacity = 4 };
static bool expected_fatal;
static unsigned original_status[capacity + 1];
static void* original_tag[capacity + 1];
static unsigned original_bytes, original_blocks;
static cmpct_heap_t* heap;

static void fatal(void) {
  __CPROVER_assert(expected_fatal, "only reject an invalid page or mismatched allocation kind");
  __CPROVER_assert(heap->remaining == original_bytes && heap->free_blocks == original_blocks,
                   "rejection preserves accounting");
  for (int i = 0; i <= heap->number_of_pages; ++i) {
    __CPROVER_assert(heap->pages[i].status == original_status[i] && heap->pages[i].tag == original_tag[i],
                     "rejection preserves the page table including the sentinel");
  }
  __CPROVER_assume(false);
}
#define FATAL(reason) fatal()
#define IRAM_ATTR
static size_t page_number(cmpct_heap_t*, void*);
static void page_free(cmpct_heap_t*, void*, int, bool);
static unsigned locks, unlocks, delegated;
static void* supplied;
static void lock(cmpct_heap_t* arg) {
  __CPROVER_assert(arg == heap && locks == 0, "lock the owning heap once");
  ++locks;
}
static void unlock(cmpct_heap_t* arg) {
  __CPROVER_assert(arg == heap && locks == 1 && unlocks == 0, "release the acquired lock");
  ++unlocks;
}
static void cmpct_free(cmpct_heap_t* arg, void* p) {
  __CPROVER_assert(arg == heap && p == supplied && locks == 0, "delegate the original small allocation");
  ++delegated;
}
#include "page_free.inc"

int main(void) {
  if (nondet_bool()) {
    // The index calculation itself is independent of the table contents.
    cmpct_heap_t header;
    uintptr_t start = nondet_uint(), ptr = nondet_uint();
    uint32_t n = nondet_uint();
    uint64_t limit = (uint64_t)start + (uint64_t)n * PAGE_SIZE;
    __CPROVER_assume(start != 0 && start % PAGE_SIZE == 0 && limit <= UINT32_MAX);
    header.page_base = (char*)start;
    header.number_of_pages = n;
    size_t index = page_number(&header, (void*)ptr);
    bool member = ptr >= start && ptr < limit && ptr % PAGE_SIZE == 0;
    __CPROVER_assert(member ? (uint64_t)start + (uint64_t)index * PAGE_SIZE == ptr : index == SIZE_MAX,
                     "index exactly the usable page starts for any representable arena");
    return 0;
  }
  int count = nondet_uint() % (capacity + 1);
  uintptr_t base = nondet_uint();
  __CPROVER_assume(base > 0 && base % PAGE_SIZE == 0 && base <= UINT32_MAX - count * PAGE_SIZE);
  heap = malloc(sizeof(*heap) + (count + 1) * sizeof(Page));
  __CPROVER_assume(heap != NULL);
  heap->page_base = (char*)base;
  heap->number_of_pages = count;
  unsigned runs = 0, free_count = 0;
  uintptr_t address = nondet_uint();
  int head = -1;
  for (int i = 0; i <= count; ++i) {
    unsigned status = i == count ? PAGE_IN_USE : nondet_uint() % 4;
    original_status[i] = heap->pages[i].status = status;
    original_tag[i] = heap->pages[i].tag = (void*)(uintptr_t)nondet_uint();
    if (status == PAGE_FREE) {
      ++free_count;
      if (i == 0 || original_status[i - 1] != PAGE_FREE) ++runs;
    }
    if (i < count && base + i * PAGE_SIZE == address) head = i;
  }
  unsigned other_bytes = nondet_uint(), other_blocks = nondet_uint();
  __CPROVER_assume(other_bytes <= UINT32_MAX - capacity * PAGE_SIZE && other_blocks <= UINT32_MAX - capacity);
  heap->remaining = original_bytes = other_bytes + free_count * PAGE_SIZE;
  heap->free_blocks = original_blocks = other_blocks + runs;

  if (nondet_bool()) {
    bool aligned = address != 0 && address % PAGE_SIZE == 0;
    expected_fatal = aligned && (head < 0 || original_status[head] == PAGE_FREE);
    supplied = (void*)address;
    cmpct_free_impl(heap, supplied);
    bool direct = head >= 0 && original_status[head] == PAGE_IN_USE;
    __CPROVER_assert(!expected_fatal && locks == (unsigned)direct && unlocks == locks &&
                     delegated == (unsigned)!direct, "dispatch the public free according to the allocation kind");
    if (!direct) {
      free(heap);
      return 0;
    }
  } else {
    bool for_malloc = nondet_bool();
    expected_fatal = head < 0 || original_status[head] != (for_malloc ? PAGE_IN_USE_FOR_MALLOCS : PAGE_IN_USE);
    page_free(heap, (void*)address, 0, for_malloc);
    __CPROVER_assert(!expected_fatal, "invalid releases reach the fatal handler");
  }
  int end = head + 1;
  while (end < count && original_status[end] == PAGE_CONTINUED) ++end;
  runs = free_count = 0;
  for (int i = 0; i <= count; ++i) {
    unsigned status = head <= i && i < end ? PAGE_FREE : original_status[i];
    __CPROVER_assert(heap->pages[i].status == status && heap->pages[i].tag == original_tag[i],
                     "release the complete run and preserve every other entry and tag");
    if (status == PAGE_FREE) {
      ++free_count;
      if (i == 0 || heap->pages[i - 1].status != PAGE_FREE) ++runs;
    }
  }
  __CPROVER_assert(heap->remaining == other_bytes + free_count * PAGE_SIZE && heap->free_blocks == other_blocks + runs,
                   "restore released bytes and count the coalesced free runs");
  free(heap);
}
