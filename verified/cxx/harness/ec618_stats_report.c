// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
bool nondet_bool(void);
#define IRAM_ATTR
#define INLINE inline
#define ASSERT(expr) ((void)0)
#define FATAL(reason) do { __CPROVER_assert(false, "valid bucket never aborts"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#include "bucket_links.inc"

static cmpct_heap_t heap;
static unsigned pages, longest, heads, locks, scans, unlocks;
static void lock(cmpct_heap_t* owner) {
  __CPROVER_assert(owner == &heap && locks == 0, "acquire the owning heap lock");
  ++locks;
}
static void unlock(cmpct_heap_t* owner) {
  __CPROVER_assert(owner == &heap && locks == 1 && scans == 1 && unlocks == 0, "release the lock after the scan");
  ++unlocks;
}

// VeriFast checks this interface on the native page_statistics loop. Only
// the fixed header is materialized here. The separately owned page statuses
// determine heads and longest, each at most the registered number of pages.
#define EC618_PAGE_STATISTICS_CONTRACT
static void page_statistics(Page* table, size_t count, size_t* largest_bytes, size_t* direct_heads) {
  __CPROVER_assert(table == heap.pages && count == pages && count <= SIZE_MAX / PAGE_SIZE &&
                   largest_bytes != direct_heads && locks == 1 && unlocks == 0, "scan exactly the registered page table under lock");
  *largest_bytes = longest * PAGE_SIZE;
  *direct_heads = heads;
  ++scans;
}
#include "stats.inc"

int main(void) {
  pages = nondet_uint();
  __CPROVER_assume(pages <= INT32_MAX / PAGE_SIZE);
  heap.number_of_pages = pages;
  longest = nondet_uint();
  heads = nondet_uint();
  __CPROVER_assume(longest <= pages && heads <= pages);

  // Every higher bucket is empty. Lower buckets may have arbitrary contents.
  free_t head;
  unsigned payload = nondet_uint();
  __CPROVER_assume(payload >= sizeof(free_t) - sizeof(header_t) && payload % NATURAL_ALIGNMENT == 0 &&
                   payload + (uint64_t)sizeof(header_t) < (1u << HEAP_ALLOC_VIRTUAL_BITS));
  head.header.size_ = ((payload + sizeof(header_t)) << 16) | 1u;
  int highest = nondet_bool() ? size_to_index_freeing(payload) : -1;
  for (int i = 0; i < NUMBER_OF_BUCKETS; ++i) {
    if (i < highest) heap.free_lists[i] = (free_t*)(uintptr_t)nondet_uint();
    else heap.free_lists[i] = i == highest ? &head : NULL;
  }

  unsigned live = nondet_uint(), free_blocks = nondet_uint();
  __CPROVER_assume((uint64_t)live + heads + free_blocks <= UINT32_MAX);
  heap.allocated_blocks = live;
  heap.free_blocks = free_blocks;
  unsigned size = nondet_uint(), free_bytes = nondet_uint();
  __CPROVER_assume(free_bytes <= size);
  heap.size = size;
  heap.remaining = free_bytes;
  void* low = heap.end_of_heap_structure = (void*)(uintptr_t)nondet_uint();
  void* high = heap.highest_address = (void*)(uintptr_t)nondet_uint();
  multi_heap_info_t info;
  cmpct_get_info_impl(&heap, &info);
  unsigned estimate = highest < 0 ? 0 : payload <= 128 ? payload : (7u * payload - 1u) / 64u * 8u;
  __CPROVER_assert(info.largest_free_block == (longest ? longest * PAGE_SIZE : estimate),
                   "page statistics take precedence over the highest occupied bucket");
  __CPROVER_assert(info.allocated_blocks == live + heads && info.free_blocks == free_blocks &&
                   info.total_blocks == free_blocks + live + heads, "report exact block counts");
  __CPROVER_assert(info.total_free_bytes == free_bytes && info.total_allocated_bytes == size - free_bytes &&
                   info.minimum_free_bytes == 0 && info.lowest_address == low && info.highest_address == high &&
                   scans == 1 && locks == 1 && unlocks == 1, "publish all byte totals and bounds under lock");
}
