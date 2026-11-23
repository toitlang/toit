// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
bool nondet_bool(void);
#define IRAM_ATTR
#define INLINE inline
#define ASSERT(expr) ((void)0)
#define FATAL(reason) do { __CPROVER_assert(false, "valid heap never aborts"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#include "bucket_links.inc"

static cmpct_heap_t* owner;
static unsigned locks, unlocks;
static void lock(cmpct_heap_t* heap) {
  __CPROVER_assert(heap == owner && locks == 0, "lock the queried heap");
  ++locks;
}
static void unlock(cmpct_heap_t* heap) {
  __CPROVER_assert(heap == owner && locks == 1 && unlocks == 0, "release the queried heap");
  ++unlocks;
}
#include "stats.inc"

int main(void) {
  enum { capacity = 4 };
  cmpct_heap_t* heap = calloc(1, sizeof(*heap) + (capacity + 1) * sizeof(Page));
  __CPROVER_assume(heap != NULL);
  owner = heap;
  unsigned count = nondet_uint() % (capacity + 1);
  heap->number_of_pages = count;
  heap->pages[count].status = PAGE_IN_USE;
  unsigned page_bytes = 0, runs = 0, heads = 0, largest = 0, length = 0;
  for (unsigned i = count; i > 0; --i) {
    unsigned status = nondet_uint() % 4;
    heap->pages[i - 1].status = status;
    if (status == PAGE_FREE) {
      if (length == 0) ++runs;
      ++length;
      if (length > largest) largest = length;
      page_bytes += PAGE_SIZE;
    } else {
      length = 0;
      if (status == PAGE_IN_USE) ++heads;
    }
  }
  free_t blocks[2];
  int highest = -1;
  unsigned payload = 0, small_free = 0, small_bytes = 0;
  for (int i = 0; i < 2; ++i) {
    if (!nondet_bool()) continue;
    unsigned bytes = nondet_uint();
    __CPROVER_assume(bytes >= sizeof(free_t) && bytes < (1u << HEAP_ALLOC_VIRTUAL_BITS) &&
                     bytes % NATURAL_ALIGNMENT == 0);
    int bucket = size_to_index_freeing(bytes - sizeof(header_t));
    blocks[i].header.size_ = (bytes << 16) | 1u;
    heap->free_lists[bucket] = &blocks[i];
    set_free_list_bit(heap, bucket);
    if (bucket >= highest) {
      highest = bucket;
      payload = bytes - sizeof(header_t);
    }
    ++small_free;
    small_bytes += bytes;
  }
  unsigned small_used = nondet_uint(), used_bytes = nondet_uint();
  __CPROVER_assume(small_used < UINT32_MAX - 8 && used_bytes <= UINT32_MAX - page_bytes - small_bytes);
  heap->allocated_blocks = small_used;
  heap->free_blocks = small_free + runs;
  heap->remaining = small_bytes + page_bytes;
  heap->size = heap->remaining + used_bytes;
  heap->end_of_heap_structure = (void*)(uintptr_t)nondet_uint();
  heap->highest_address = (void*)(uintptr_t)nondet_uint();
  multi_heap_info_t info;
  cmpct_get_info_impl(heap, &info);
  __CPROVER_assert(info.free_blocks == small_free + runs && info.allocated_blocks == small_used + heads &&
                   info.total_blocks == small_free + runs + small_used + heads,
                   "count each page run and direct allocation head exactly once");
  unsigned small_limit = payload <= 128 ? payload : (7u * payload - 1u) / 64u * 8u;
  __CPROVER_assert(info.largest_free_block == (largest ? largest * PAGE_SIZE : small_limit),
                   "report the longest page run or the size estimate of the highest occupied bucket");
  __CPROVER_assert(info.total_free_bytes == page_bytes + small_bytes && info.total_allocated_bytes == used_bytes &&
                   info.minimum_free_bytes == 0 && info.lowest_address == heap->end_of_heap_structure &&
                   info.highest_address == heap->highest_address && locks == 1 && unlocks == 1,
                   "report byte totals and region bounds and release the lock");
}
