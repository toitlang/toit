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
#define DEBUG_ASSERT(expr) __CPROVER_assert((expr), "returned extent is page sized")
#define FATAL(reason) do { __CPROVER_assert(false, "valid extent never aborts"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#include "bucket_links.inc"

static cmpct_heap_t heap;
static arena_t *arena, *next, *previous;
static size_t bytes, calls;
static bool whole_pages, previous_page_free, next_page_free;
static void page_free(cmpct_heap_t* owner, void* base, int pages, bool for_malloc) {
  __CPROVER_assert(whole_pages && owner == &heap && base == arena && for_malloc,
                   "release only the complete page-backed arena to the owning heap");
  __CPROVER_assert((uint64_t)pages * PAGE_SIZE == bytes, "return the exact page count");
  __CPROVER_assert(next->previous == previous && previous->next == next,
                   "detach the arena before handing its storage back");
  // Accounting contract of the page-table operation in ec618_page_free.c.
  owner->remaining += bytes;
  if (!previous_page_free && !next_page_free) ++owner->free_blocks;
  if (previous_page_free && next_page_free) --owner->free_blocks;
  ++calls;
}
#include "reclaim.inc"

int main(void) {
  unsigned size = nondet_uint(), left_width = nondet_uint();
  bool start = nondet_bool(), end = nondet_bool();
  __CPROVER_assume(size >= sizeof(free_t) && size < (1u << HEAP_ALLOC_VIRTUAL_BITS));
  __CPROVER_assume(left_width >= sizeof(header_t) && left_width < (1u << HEAP_ALLOC_VIRTUAL_BITS));
  __CPROVER_assume(((size | left_width) % NATURAL_ALIGNMENT) == 0);
  __CPROVER_assume(!start || left_width == sizeof(header_t));
  unsigned offset = nondet_uint();
  __CPROVER_assume(offset < PAGE_SIZE && offset % NATURAL_ALIGNMENT == 0);
  bytes = sizeof(arena_t) + left_width + size + sizeof(header_t);
  char* storage = malloc(bytes + offset);
  __CPROVER_assume(storage != NULL);
  arena = (arena_t*)(storage + offset);
  header_t* left = (header_t*)(arena + 1);
  free_t* block = (free_t*)((char*)left + left_width);
  header_t* right = (header_t*)((char*)block + size);
  left->size_ = (left_width << 16) | (start ? 0 : NATURAL_ALIGNMENT);
  unsigned right_size = end ? 0 : sizeof(free_t);
  right->size_ = (right_size << 16) | NATURAL_ALIGNMENT;
  arena_t peer;
  previous = &heap.arenas;
  next = nondet_bool() ? previous : &peer;
  arena->next = next;
  arena->previous = previous;
  next->previous = previous->next = arena;
  whole_pages = start && end && (uintptr_t)arena % PAGE_SIZE == 0 && bytes % PAGE_SIZE == 0;
  int bucket = size_to_index_freeing(size - sizeof(header_t));
  free_t existing = {0};
  free_t* old_head = nondet_bool() ? &existing : NULL;
  if (old_head) {
    heap.free_lists[bucket] = old_head;
    set_free_list_bit(&heap, bucket);
  }
  previous_page_free = nondet_bool();
  next_page_free = nondet_bool();
  unsigned old_bytes = nondet_uint(), old_blocks = nondet_uint(), old_size = nondet_uint();
  __CPROVER_assume(old_bytes <= UINT32_MAX - bytes && old_blocks >= 2 && old_blocks < UINT32_MAX);
  __CPROVER_assume(old_size <= UINT32_MAX - sizeof(arena_t) - 2 * sizeof(header_t));
  heap.size = old_size;
  heap.remaining = old_bytes;
  heap.free_blocks = old_blocks;
  // The absorbed header can already be marked from merging with its left neighbor.
  free_memory(&heap, &block->header, left_width | (unsigned)nondet_bool(), size);
  __CPROVER_assert(calls == (unsigned)whole_pages, "release exactly the eligible arenas");
  __CPROVER_assert(heap.size == old_size + (whole_pages ? sizeof(arena_t) + 2 * sizeof(header_t) : 0),
                   "restore arena overhead exactly on page return");
  unsigned expected_blocks = old_blocks + 1;
  if (whole_pages) expected_blocks -= (unsigned)previous_page_free + (unsigned)next_page_free;
  __CPROVER_assert(heap.remaining == old_bytes + (whole_pages ? bytes : size) &&
                   heap.free_blocks == expected_blocks, "count the resulting free blocks and bytes");
  __CPROVER_assert(heap.free_lists[bucket] == (whole_pages ? old_head : block),
                   "publish the merged block or restore the prior bucket head");
  __CPROVER_assert(existing.prev == ((!whole_pages && old_head) ? block : NULL),
                   "restore or install the previous link of the old head");
  bool present = (heap.free_list_bits[bucket >> 5] & (1u << (31 - (bucket & 31)))) != 0;
  __CPROVER_assert(present == (!whole_pages || old_head != NULL), "bucket bitmap matches its list");
  if (!whole_pages) {
    __CPROVER_assert(block->header.size_ == ((size << 16) | left_width | 1u) &&
                     right->size_ == ((right_size << 16) | size), "publish both outer boundary tags");
    __CPROVER_assert(block->prev == NULL && block->next == old_head, "link the retained block");
    __CPROVER_assert(next->previous == arena && previous->next == arena, "retain the arena links");
  }
}
