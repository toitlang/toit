// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/types.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
bool nondet_bool(void);
#define IRAM_ATTR
#define INLINE inline
#define ASSERT(expr) ((void)0)
#define LTRACEF(...)
#define FATAL(reason) do { __CPROVER_assert(false, "valid arena construction never aborts"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#include "bucket_links.inc"

static cmpct_heap_t* owner;
static bool locked;
static unsigned locks, unlocks, reserves, allocations;
static unsigned request, block_bytes, pages_needed;
static char* area;
static free_t* existing;
static void* returned;
static void* thread_tag;
static bool direct;
#define GET_THREAD_LOCAL_TAG thread_tag

static void lock(cmpct_heap_t* heap) {
  __CPROVER_assert(heap == owner && !locked, "acquire the owning heap lock");
  locked = true;
  ++locks;
}
static void unlock(cmpct_heap_t* heap) {
  __CPROVER_assert(heap == owner && locked, "release a held lock");
  locked = false;
  ++unlocks;
}
static void* page_alloc(cmpct_heap_t* heap, intptr_t pages, uintptr_t alignment, void* tag, bool for_malloc) {
  if (direct) {
    __CPROVER_assert(heap == owner && locked && reserves == 0 && alignment == PAGE_SIZE &&
                     tag == thread_tag && !for_malloc, "send direct page requests under the calling thread tag");
    __CPROVER_assert(pages == ((uint64_t)request + PAGE_SIZE - 1) / PAGE_SIZE,
                     "round the full byte request up to pages without overflow");
    ++reserves;
    return returned;
  }
  __CPROVER_assert(heap == owner && locked && !existing && reserves == 0, "grow only on a locked bucket miss");
  __CPROVER_assert(pages == pages_needed && alignment == PAGE_SIZE && !tag && for_malloc,
                   "request the minimum whole-page extent for the rounded block and arena headers");
  ++reserves;
  if (area) {
    // The page allocator charges the full run before heap_grow converts it.
    heap->remaining -= pages_needed * PAGE_SIZE;
    --heap->free_blocks;
  }
  return area;
}
static ssize_t heap_grow(cmpct_heap_t*, free_t**, int);
static void* allocation_tail(cmpct_heap_t* heap, free_t* head, size_t size, size_t rounded, int bucket) {
  free_t* expected = existing ? existing : (free_t*)(area + sizeof(arena_t) + sizeof(header_t));
  __CPROVER_assert(locked && heap == owner && head == expected && heap->free_lists[bucket] == expected,
                   "pass the selected block to the allocation tail with the lock held");
  __CPROVER_assert(size == request && rounded == block_bytes && get_size(&head->header) >= rounded,
                   "selected block holds the complete rounded allocation");
  ++allocations;
  unlock(heap);
  return returned;
}
#include "growth.inc"

int main(void) {
  cmpct_heap_t heap = {0};
  owner = &heap;
  unsigned raw = nondet_uint();
  bool public_entry = nondet_bool();
  if (public_entry && raw >= PAGE_SIZE * 3 / 4 && (raw <= PAGE_SIZE || raw > PAGE_SIZE * 3 / 2)) {
    direct = true;
    request = raw;
    thread_tag = (void*)(uintptr_t)nondet_uint();
    returned = (void*)(uintptr_t)nondet_uint();
    void* result = cmpct_malloc_impl(&heap, raw);
    __CPROVER_assert(result == returned && reserves == 1 && !allocations && !locked && locks == 1 && unlocks == 1,
                     "propagate direct page success or failure and balance the lock");
    return 0;
  }
  __CPROVER_assume(raw <= SMALL_ALLOCATION_LIMIT);
  request = raw ? raw : 1;
  size_t payload;
  int minimum_bucket = size_to_index_allocating(request, &payload);
  block_bytes = payload + sizeof(header_t);
  unsigned overhead = sizeof(arena_t) + 2 * sizeof(header_t);
  pages_needed = (block_bytes + overhead + PAGE_SIZE - 1) / PAGE_SIZE;
  unsigned extent = pages_needed * PAGE_SIZE;

  free_t old;
  if (nondet_bool()) {
    existing = &old;
    old.header.size_ = (block_bytes << 16) | 1u;
    heap.free_lists[minimum_bucket] = &old;
    set_free_list_bit(&heap, minimum_bucket);
  }
  if (!existing && nondet_bool()) {
    area = malloc(extent);
    __CPROVER_assume(area != NULL);
  }
  arena_t prior;
  bool prior_arena = nondet_bool();
  arena_t* next = prior_arena ? &prior : &heap.arenas;
  heap.arenas.next = next;
  heap.arenas.previous = next;
  if (prior_arena) prior.next = prior.previous = &heap.arenas;
  unsigned original_size = nondet_uint(), original_remaining = nondet_uint();
  __CPROVER_assume(original_size >= original_remaining && original_remaining >= extent);
  heap.size = original_size;
  heap.remaining = original_remaining;
  heap.free_blocks = 1 + (existing != NULL);
  returned = (void*)(uintptr_t)nondet_uint();
  void* result = public_entry ? cmpct_malloc_impl(&heap, raw) : cmpct_alloc(&heap, raw);
  bool success = existing || area;
  __CPROVER_assert(!locked && locks == 1 && unlocks == 1 && reserves == !existing && allocations == success &&
                   result == (success ? returned : NULL), "balance locks and propagate hits, growth and exhaustion");
  __CPROVER_assert(heap.size == original_size - (area ? overhead : 0) &&
                   heap.remaining == original_remaining - (area ? overhead : 0) &&
                   heap.free_blocks == 1u + (existing != NULL), "charge only the new arena bookkeeping");
  if (area) {
    arena_t* node = (arena_t*)area;
    header_t* left = (header_t*)(node + 1);
    free_t* block = (free_t*)(left + 1);
    header_t* right = (header_t*)(area + extent - sizeof(header_t));
    unsigned free_size = extent - overhead;
    __CPROVER_assert(heap.arenas.next == node && node->previous == &heap.arenas && node->next == next &&
                     next->previous == node, "splice the new arena before the old first arena");
    __CPROVER_assert(left->size_ == sizeof(header_t) << 16 && !left->tag && right->size_ == free_size && !right->tag,
                     "bound the new block with allocated sentinels");
    __CPROVER_assert(block->header.size_ == ((free_size << 16) | sizeof(header_t) | 1u) && !block->prev && !block->next,
                     "publish the entire arena interior as one free block");
    free(area);
  } else {
    __CPROVER_assert(heap.arenas.next == next && next->previous == &heap.arenas, "preserve the arena list without growth");
  }
}
