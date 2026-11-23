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
#define FATAL(reason) do { __CPROVER_assert(false, "valid aligned allocation never aborts"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#include "bucket_links.inc"

static unsigned requested, alignment, payload, extent, left_size, neighbor_word;
static unsigned locks, unlocks, paged, delegated, searches, tails;
static cmpct_heap_t* owner;
static free_t* selected;
static void *forwarded, *thread_tag, *tail_result;
#include "aligned_prefix.inc"

// CBMC backs each selected block with a fresh object. Give that object's
// payload an arbitrary board address while preserving offsets within it.
static uintptr_t physical_payload;
static size_t board_prefix(uintptr_t actual, size_t align) {
  __CPROVER_assert(selected && actual == (uintptr_t)(&selected->header + 1) && align == alignment,
                   "align the first payload of the selected block");
  return aligned_prefix(physical_payload, align);
}
#define GET_THREAD_LOCAL_TAG thread_tag

static void lock(cmpct_heap_t* heap) {
  __CPROVER_assert(heap == owner && locks == 0, "lock the owning heap once");
  ++locks;
}
static void unlock(cmpct_heap_t* heap) {
  __CPROVER_assert(heap == owner && locks == 1 && unlocks == 0, "release the held lock");
  ++unlocks;
}
void* cmpct_malloc_impl(cmpct_heap_t* heap, size_t bytes) {
  __CPROVER_assert(heap == owner && !locks && bytes == requested, "delegate natural alignment with the original size");
  ++delegated;
  return forwarded;
}
static void* page_alloc(cmpct_heap_t* heap, intptr_t pages, uintptr_t align, void* tag, bool for_malloc) {
  __CPROVER_assert(heap == owner && locks == 1 && unlocks == 0 && tag == thread_tag && !for_malloc &&
                   align == alignment && pages == ((uint64_t)requested + PAGE_SIZE - 1) / PAGE_SIZE,
                   "forward exact alignment and rounded page count under the calling tag");
  ++paged;
  return forwarded;
}
static int get_bucket_for_size(cmpct_heap_t* heap, size_t bytes, int start) {
  ++searches;
  size_t rounded;
  int bucket = size_to_index_allocating(payload + alignment + sizeof(free_t) - NATURAL_ALIGNMENT, &rounded);
  __CPROVER_assert(heap == owner && locks == 1 && !unlocks && start == bucket && bytes == rounded + sizeof(header_t),
                   "reserve the bucket-rounded extent including room for a leading free block");
  if (!selected) {
    unlock(heap);
    return -1;
  }
  __CPROVER_assume(extent >= bytes);
  return size_to_index_freeing(extent - sizeof(header_t));
}
static void* allocation_tail(cmpct_heap_t* heap, free_t* head, size_t bytes, size_t rounded, int bucket) {
  size_t prefix = (char*)head - (char*)selected;
  unsigned available = extent - prefix;
  void* result = &head->header + 1;
  __CPROVER_assert(heap == owner && locks == 1 && !unlocks && bytes == payload && rounded == bytes + sizeof(header_t) &&
                   prefix == aligned_prefix(physical_payload, alignment) &&
                   prefix <= extent && rounded <= available && ((physical_payload + prefix) & (alignment - 1)) == 0,
                   "deliver an aligned payload with space for the request");
  __CPROVER_assert(bucket == size_to_index_freeing(available - sizeof(header_t)) && heap->free_lists[bucket] == head &&
                   (head->header.size_ >> 16) == available, "select the complete aligned free block in its bucket");
  header_t* right = (header_t*)((char*)selected + extent);
  __CPROVER_assert(right->size_ == ((neighbor_word & 0xffff0001u) | available) &&
                   heap->remaining == extent && heap->free_blocks == (prefix ? 2u : 1u),
                   "preserve the right neighbor and account for both free fragments");
  if (prefix) {
    __CPROVER_assert(prefix >= sizeof(free_t) && selected->header.size_ == ((prefix << 16) | left_size | 1u) &&
                     (head->header.size_ & 0xffff) == (prefix | 1u), "preserve both boundary tags across the prefix split");
    int before = size_to_index_freeing(prefix - sizeof(header_t));
    __CPROVER_assert(before == bucket ? head->next == selected && selected->prev == head :
                     heap->free_lists[before] == selected && !selected->prev, "keep the prefix reachable in its free list");
  }
  tail_result = result;
  ++tails;
  unlock(heap);
  return result;
}
#define aligned_prefix board_prefix
#include "aligned.inc"
#undef aligned_prefix

int main(void) {
  if (nondet_bool()) {
    uintptr_t address = nondet_uint();
    unsigned shift = 4 + nondet_uint() % 7;
    unsigned step = 1u << shift;
    __CPROVER_assume(address % NATURAL_ALIGNMENT == 0);
    uint64_t next = (((uint64_t)address + step - 1) >> shift) << shift;
    if (next > address && next - address < sizeof(free_t)) next += step;
    size_t skip = aligned_prefix(address, step);
    __CPROVER_assert((uint64_t)address + skip == next && skip <= step + sizeof(free_t) - NATURAL_ALIGNMENT,
                     "choose the first aligned address leaving a representable prefix for every address residue");
    return 0;
  }
  cmpct_heap_t heap = {0};
  owner = &heap;
  requested = nondet_uint();
  alignment = nondet_uint();
  forwarded = (void*)(uintptr_t)nondet_uint();
  thread_tag = (void*)(uintptr_t)nondet_uint();
  bool valid = alignment != 0 && (alignment & (alignment - 1u)) == 0;
  bool page = valid && (alignment >= PAGE_SIZE / 2 || requested >= PAGE_SIZE * 3 / 4);
  bool natural = valid && !page && alignment <= NATURAL_ALIGNMENT;
  bool small = valid && !page && !natural;
  char* backing = NULL;
  if (small) {
    payload = (requested + 7) / 8 * 8;
    if (payload < sizeof(free_t)) payload = sizeof(free_t);
    if (nondet_bool()) {
      extent = nondet_uint();
      __CPROVER_assume(extent >= sizeof(free_t) && extent < (1u << HEAP_ALLOC_VIRTUAL_BITS) && extent % 8 == 0);
      physical_payload = nondet_uint();
      __CPROVER_assume(physical_payload >= sizeof(header_t) && physical_payload % NATURAL_ALIGNMENT == 0 &&
                       physical_payload <= UINT32_MAX - extent);
      backing = malloc(extent + sizeof(header_t));
      __CPROVER_assume(backing != NULL);
      selected = (free_t*)backing;
      left_size = nondet_uint() & 0xfff8;
      selected->header.size_ = (extent << 16) | left_size | 1u;
      selected->next = selected->prev = NULL;
      neighbor_word = (nondet_uint() & 0xffff0001u) | extent;
      ((header_t*)((char*)selected + extent))->size_ = neighbor_word;
      int index = size_to_index_freeing(extent - sizeof(header_t));
      heap.free_lists[index] = selected;
      set_free_list_bit(&heap, index);
      heap.free_blocks = 1;
      heap.remaining = extent;
    }
  }
  void* result = cmpct_aligned_alloc_impl(&heap, requested, alignment);
  __CPROVER_assert(paged == page && delegated == natural && searches == small && tails == (selected != NULL) &&
                   locks == (unsigned)(page || small) && locks == unlocks, "dispatch and balance locks on every path");
  if (!selected) __CPROVER_assert(result == (page || natural ? forwarded : NULL), "propagate delegation or rejection");
  else __CPROVER_assert(result != NULL && result == tail_result, "return the exact aligned allocation");
  free(backing);
}
