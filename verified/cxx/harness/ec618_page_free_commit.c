// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
bool nondet_bool(void);
static cmpct_heap_t* heap;
static unsigned head, end, probe, original_bytes, original_runs, saved_status, releases;
static void* saved_tag;
static bool valid;

static size_t release_page_run(Page*);
static void fatal(void) {
  __CPROVER_assert(!valid && releases == 0, "reject only invalid requests before releasing continuations");
  __CPROVER_assert(heap->remaining == original_bytes && heap->free_blocks == original_runs &&
                   heap->pages[probe].status == saved_status && heap->pages[probe].tag == saved_tag,
                   "rejection preserves counters and every descriptor");
  __CPROVER_assume(false);
}
#define FATAL(reason) fatal()
#define IRAM_ATTR
#include "page_free_commit.inc"

// The proved operation updates one head and its decoded continuation prefix.
// Observe its effects at an arbitrary descriptor; neighboring free-run
// statuses used by the caller lie outside that interval.
static size_t release_page_run(Page* table) {
  __CPROVER_assert(valid && !releases && table == &heap->pages[head],
                   "release the selected head and its continuation prefix exactly once");
  if (head <= probe && probe < end) heap->pages[probe].status = PAGE_FREE;
  ++releases;
  return end - head;
}

int main(void) {
  unsigned count = nondet_uint();
  uintptr_t base = nondet_uint(), address = nondet_uint();
  __CPROVER_assume(count <= INT32_MAX / PAGE_SIZE && base && base % PAGE_SIZE == 0 &&
                   (uint64_t)base + (uint64_t)count * PAGE_SIZE <= UINT32_MAX);
  heap = malloc(sizeof(*heap) + (count + 1) * sizeof(Page));
  __CPROVER_assume(heap != NULL);
  heap->number_of_pages = count;
  heap->page_base = (char*)base;
  probe = nondet_uint();
  __CPROVER_assume(probe <= count);
  heap->pages[probe].status = nondet_uint() % 4;
  heap->pages[count].status = PAGE_IN_USE;
  bool arena = nondet_bool(), left_free = false, right_free = false;
  unsigned charge = 0;
  bool member = address >= base && address % PAGE_SIZE == 0 &&
                address < (uint64_t)base + (uint64_t)count * PAGE_SIZE;
  if (member) {
    head = (address - base) / PAGE_SIZE;
    unsigned kind = nondet_uint() % 4;
    heap->pages[head].status = kind;
    valid = kind == (arena ? PAGE_IN_USE_FOR_MALLOCS : PAGE_IN_USE);
    if (valid) {
      unsigned pages = nondet_uint();
      __CPROVER_assume(pages > 0 && pages <= count - head);
      end = head + pages;
      charge = pages * PAGE_SIZE;
      if (head < probe && probe < end) heap->pages[probe].status = PAGE_CONTINUED;
      if (head > 0) {
        heap->pages[head - 1].status = nondet_uint() % 4;
        left_free = heap->pages[head - 1].status == PAGE_FREE;
      }
      if (end < count) heap->pages[end].status = nondet_uint() % 3;
      right_free = heap->pages[end].status == PAGE_FREE;
    }
  }
  unsigned outside_runs = nondet_uint();
  original_bytes = nondet_uint();
  __CPROVER_assume(outside_runs <= UINT32_MAX - 2 && original_bytes <= UINT32_MAX - charge);
  original_runs = outside_runs + left_free + right_free;
  heap->free_blocks = original_runs;
  heap->remaining = original_bytes;
  saved_status = heap->pages[probe].status;
  saved_tag = heap->pages[probe].tag = (void*)(uintptr_t)nondet_uint();
  page_free(heap, (void*)address, 0, arena);
  __CPROVER_assert(valid && releases == 1, "only a matching live head returns successfully");
  __CPROVER_assert(heap->pages[probe].status == (head <= probe && probe < end ? PAGE_FREE : saved_status) &&
                   heap->pages[probe].tag == saved_tag, "free exactly the run and preserve every tag and the sentinel");
  __CPROVER_assert(heap->remaining == original_bytes + charge && heap->free_blocks == outside_runs + 1,
                   "restore the full byte extent and merge both neighboring free runs into one");
}
