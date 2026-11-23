// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
bool nondet_bool(void);
static bool expect_fatal;
#define IRAM_ATTR
#define INLINE inline
#define ASSERT(expr) ((void)0)
#define FATAL(reason) do { __CPROVER_assert(expect_fatal, "only invalid aligned requests abort"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#include "bucket_links.inc"
static size_t page_number(cmpct_heap_t*, void*);
static size_t page_allocation_bytes(Page*);
#include "allocation_query.inc"
#define page_allocation_bytes native_allocation_bytes
#include "allocation_span.inc"
#undef page_allocation_bytes

static Page* expected_head;
static unsigned run_pages, scans;
static size_t page_allocation_bytes(Page* head) {
  __CPROVER_assert(expected_head != NULL && head == expected_head && !scans,
                   "scan exactly the selected direct allocation head");
  ++scans;
  if (run_pages <= 4) return native_allocation_bytes(head);
  // The read-only VeriFast contract handles all lengths through the sentinel.
  return run_pages * PAGE_SIZE;
}

int main(void) {
  if (nondet_bool()) {
    unsigned extent = nondet_uint();
    __CPROVER_assume(extent >= sizeof(free_t) && extent < (1u << HEAP_ALLOC_VIRTUAL_BITS) &&
                     extent % NATURAL_ALIGNMENT == 0);
    char* storage = malloc(extent + PAGE_SIZE + NATURAL_ALIGNMENT);
    __CPROVER_assume(storage != NULL);
    char* start = storage + sizeof(header_t);
    unsigned padding = (0u - (uintptr_t)start) & (PAGE_SIZE - 1);
    char* boundary = start + padding;
    bool aligned = nondet_bool();
    char* payload = boundary + (aligned ? 0 : NATURAL_ALIGNMENT);
    ((header_t*)payload)[-1].size_ = (extent << 16) | (nondet_uint() & 0xfff8);
    cmpct_heap_t* heap = malloc(sizeof(*heap) + 2 * sizeof(Page));
    __CPROVER_assume(heap != NULL);
    heap->number_of_pages = 1;
    heap->page_base = boundary;
    heap->pages[0].status = nondet_bool() ? PAGE_IN_USE_FOR_MALLOCS : PAGE_CONTINUED;
    __CPROVER_assert(cmpct_get_allocated_size_impl(heap, payload) == extent - sizeof(header_t) && !scans,
                     "aligned and unaligned small allocations use the packed block size");
    return 0;
  }

  unsigned count = nondet_uint(), index = nondet_uint();
  uintptr_t base = nondet_uint();
  __CPROVER_assume(count > 0 && count <= INT32_MAX / PAGE_SIZE && index < count);
  __CPROVER_assume(base > 0 && base % PAGE_SIZE == 0 && base + (uint64_t)count * PAGE_SIZE <= UINT32_MAX);
  cmpct_heap_t* heap = malloc(sizeof(*heap) + (count + 1) * sizeof(Page));
  __CPROVER_assume(heap != NULL);
  heap->page_base = (char*)base;
  heap->number_of_pages = count;
  heap->pages[count].status = PAGE_IN_USE;
  unsigned mode = nondet_uint() % 4;
  void* ptr = (void*)(base + index * PAGE_SIZE);
  size_t expected = 0;
  if (mode == 0) {
    ptr = NULL;
  } else if (mode == 1) {
    heap->pages[index].status = PAGE_FREE;
    expect_fatal = true;
  } else if (mode == 2) {
    ptr = (void*)(base + count * PAGE_SIZE);
    expect_fatal = true;
  } else {
    heap->pages[index].status = PAGE_IN_USE;
    expected_head = &heap->pages[index];
    run_pages = nondet_uint();
    __CPROVER_assume(run_pages > 0 && run_pages <= count - index);
    expected = run_pages * PAGE_SIZE;
    if (run_pages <= 4) {
      for (unsigned i = 1; i < run_pages; ++i) expected_head[i].status = PAGE_CONTINUED;
      if (index + run_pages < count) expected_head[run_pages].status = nondet_uint() % 3;
    }
  }
  size_t result = cmpct_get_allocated_size_impl(heap, ptr);
  __CPROVER_assert(!expect_fatal && result == expected && scans == (mode == 3),
                   "return the full live extent or zero for null and reject invalid page addresses");
}
