// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

unsigned nondet_uint(void);
intptr_t nondet_word(void);
bool nondet_bool(void);
#include "cmpctmalloc.h"
#include "arena_types.inc"

static int* cleared;
static size_t cleared_count;
static unsigned clear_calls;
static void clear_words(int* base, size_t count) {
  ++clear_calls;
  cleared = base;
  cleared_count = count;
}
#define IRAM_ATTR
#include "page_alloc.inc"

int main() {
  enum { capacity = 4 };
  cmpct_heap_t* heap = malloc(sizeof(*heap) + (capacity + 1) * sizeof(Page));
  __CPROVER_assume(heap != NULL);
  uintptr_t base = nondet_uint();
  __CPROVER_assume(base != 0 && base % PAGE_SIZE == 0 && base <= UINT32_MAX - capacity * PAGE_SIZE);
  const int count = nondet_uint() % (capacity + 1);
  const intptr_t requested = nondet_word();
  unsigned shift = nondet_uint() % 32;
  const uintptr_t alignment = ((uintptr_t)1) << shift;
  const bool for_malloc = nondet_bool();
  void* tag = (void*)(uintptr_t)nondet_uint();

  heap->page_base = (char*)base;
  heap->number_of_pages = count;
  unsigned previous_status[capacity + 1];
  void* previous_tag[capacity + 1];
  unsigned runs = 0, free_count = 0;
  for (int i = 0; i <= count; ++i) {
    unsigned status = i == count ? PAGE_IN_USE : nondet_uint() % 4;
    previous_status[i] = heap->pages[i].status = status;
    previous_tag[i] = heap->pages[i].tag = (void*)(uintptr_t)nondet_uint();
    if (status == PAGE_FREE) {
      ++free_count;
      if (!i || previous_status[i - 1] != PAGE_FREE) ++runs;
    }
  }
  // Include the contribution of the allocator's small-block arenas in both counters.
  const unsigned other_bytes = nondet_uint();
  const unsigned other_blocks = nondet_uint();
  __CPROVER_assume(other_bytes <= UINT32_MAX - capacity * PAGE_SIZE && other_blocks <= UINT32_MAX - capacity);
  heap->free_blocks = other_blocks + runs;
  heap->remaining = other_bytes + free_count * PAGE_SIZE;

  // Compute first fit backwards from the length of each free suffix.
  int expected = -1, length = 0;
  for (int i = count - 1; i >= 0; --i) {
    length = previous_status[i] == PAGE_FREE ? length + 1 : 0;
    uintptr_t address = base + i * PAGE_SIZE;
    if (requested > 0 && requested <= length && ((address >> shift) << shift) == address) expected = i;
  }
  void* result = page_alloc(heap, requested, alignment, tag, for_malloc);
  bool success = expected >= 0;
  __CPROVER_assert(result == (success ? (void*)(base + expected * PAGE_SIZE) : NULL), "select the first aligned free run");
  __CPROVER_assert(clear_calls == (unsigned)success, "only clear a successful allocation");
  if (success) {
    __CPROVER_assert(cleared == result && cleared_count * sizeof(int) == (uint64_t)requested * PAGE_SIZE,
                "clear every word of the returned extent");
  }
  runs = free_count = 0;
  for (int i = 0; i <= count; ++i) {
    bool head = success && i == expected;
    bool tail = success && expected < i && i < expected + requested;
    unsigned expected_status = head ? (for_malloc ? PAGE_IN_USE_FOR_MALLOCS : PAGE_IN_USE) :
                               tail ? PAGE_CONTINUED : previous_status[i];
    __CPROVER_assert(heap->pages[i].status == expected_status && heap->pages[i].tag == (head ? tag : previous_tag[i]),
                "mark exactly the selected pages and preserve unrelated tags and the sentinel");
    if (heap->pages[i].status == PAGE_FREE) {
      ++free_count;
      if (!i || heap->pages[i - 1].status != PAGE_FREE) ++runs;
    }
  }
  __CPROVER_assert(heap->free_blocks == other_blocks + runs && heap->remaining == other_bytes + free_count * PAGE_SIZE,
              "charge exactly the consumed bytes and maintain the number of free runs");
  free(heap);
}
