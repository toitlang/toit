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
#define FATAL(reason) do { __CPROVER_assert(false, "valid block layout never aborts"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#include "bucket_links.inc"

static void *thread_tag, *expected_payload;
static size_t payload_bytes;
static unsigned clears, unlocks;
static cmpct_heap_t* owner;
#define GET_THREAD_LOCAL_TAG thread_tag
static void clear_words(int* base, size_t words) {
  __CPROVER_assert(base == expected_payload && words * (uint64_t)sizeof(int) == payload_bytes,
                   "clear precisely the entire usable payload including unsplit slack");
  ++clears;
}
static void unlock(cmpct_heap_t* heap) {
  __CPROVER_assert(heap == owner && clears == 1, "release the owner lock after clearing the payload");
  ++unlocks;
}
#include "split.inc"

int main(void) {
  unsigned total = nondet_uint(), request = nondet_uint(), rounded = nondet_uint();
  __CPROVER_assume(total >= sizeof(free_t) && total < (1u << HEAP_ALLOC_VIRTUAL_BITS) && total % NATURAL_ALIGNMENT == 0);
  __CPROVER_assume(request > 0 && rounded >= sizeof(free_t) && rounded <= total &&
                   rounded % NATURAL_ALIGNMENT == 0 && request <= rounded - sizeof(header_t));
  unsigned leftover = total - rounded;
  bool split = leftover >= sizeof(free_t) && (uint64_t)leftover * 32 > request;
  unsigned used = split ? rounded : total;
  char* arena = malloc(total + sizeof(header_t));
  __CPROVER_assume(arena != NULL);
  free_t* head = (free_t*)arena;
  header_t* right = (header_t*)(arena + total);
  unsigned left = nondet_uint();
  __CPROVER_assume(left <= 0xffff && left % NATURAL_ALIGNMENT == 0);
  head->header.size_ = (total << 16) | left | 1u;
  head->next = head->prev = NULL;
  unsigned right_size = nondet_uint() & 0xfff8, right_mark = nondet_uint() & 1;
  right->size_ = (right_size << 16) | total | right_mark;
  void* right_tag = right->tag = (void*)(uintptr_t)nondet_uint();
  cmpct_heap_t heap = {0};
  owner = &heap;
  int bucket = size_to_index_freeing(total - sizeof(header_t));
  int rest_bucket = split ? size_to_index_freeing(leftover - sizeof(header_t)) : -1;
  free_t sibling = {0}, existing = {0};
  bool has_sibling = nondet_bool();
  bool has_existing = split && bucket != rest_bucket && nondet_bool();
  if (has_sibling) {
    sibling.header.size_ = total << 16 | 1u;
    head->next = &sibling;
    sibling.prev = head;
  }
  if (has_existing) {
    existing.header.size_ = leftover << 16 | 1u;
    heap.free_lists[rest_bucket] = &existing;
    set_free_list_bit(&heap, rest_bucket);
  }
  heap.free_lists[bucket] = head;
  set_free_list_bit(&heap, bucket);
  unsigned other_bytes = (has_sibling ? total : 0) + (has_existing ? leftover : 0);
  heap.remaining = total + other_bytes;
  heap.free_blocks = 1 + (unsigned)has_sibling + (unsigned)has_existing;
  heap.allocated_blocks = nondet_uint();
  __CPROVER_assume(heap.allocated_blocks < UINT32_MAX);
  unsigned old_allocated = heap.allocated_blocks;
  thread_tag = (void*)(uintptr_t)nondet_uint();
  expected_payload = &head->header + 1;
  payload_bytes = used - sizeof(header_t);
  void* result = allocation_tail(&heap, head, request, rounded, bucket);
  __CPROVER_assert(result == expected_payload && head->header.size_ == ((used << 16) | left) &&
                   head->header.tag == thread_tag && unlocks == 1, "publish a correctly sized and tagged allocation");
  __CPROVER_assert(right->size_ == ((right_size << 16) | (split ? leftover : total) | right_mark) &&
                   right->tag == right_tag, "preserve the neighbor and set its exact left extent");
  __CPROVER_assert(heap.remaining == total - used + other_bytes &&
                   heap.free_blocks == (unsigned)split + (unsigned)has_sibling + (unsigned)has_existing &&
                   heap.allocated_blocks == old_allocated + 1, "account exactly for the block and its remainder");
  free_t* rest = NULL;
  if (split) {
    rest = (free_t*)(arena + used);
    free_t* following = has_existing ? &existing : (bucket == rest_bucket && has_sibling ? &sibling : NULL);
    __CPROVER_assert(rest->header.size_ == ((leftover << 16) | used | 1u) && !rest->prev && rest->next == following &&
                     (!following || following->prev == rest),
                     "place the residual free block immediately after the allocation");
  }
  unsigned probe = nondet_uint() % NUMBER_OF_BUCKETS;
  if (has_sibling && bucket != rest_bucket) {
    __CPROVER_assert(!sibling.prev, "the old bucket successor becomes its head");
  }
  free_t* expected = (int)probe == rest_bucket ? rest : ((int)probe == bucket && has_sibling ? &sibling : NULL);
  __CPROVER_assert(heap.free_lists[probe] == expected &&
                   ((heap.free_list_bits[probe / 32] >> (31 - probe % 32)) & 1u) == (expected != NULL),
                   "publish exactly the residual free block in the correct bucket");
  free(arena);
}
