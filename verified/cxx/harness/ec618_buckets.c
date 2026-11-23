// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
int nondet_int(void);
bool nondet_bool(void);

#define IRAM_ATTR
#define FATAL(reason) do { __CPROVER_assert(false, "valid free blocks never abort"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#define INLINE inline
#define ASSERT(expr) ((void)0)
#include "bucket_links.inc"

// First come the exact eight-byte sizes, then eight equal steps per doubling.
static unsigned bucket_size(unsigned bucket) {
  if (bucket < 15) return 8 * (bucket + 1);
  unsigned row = (bucket - 15) / 8;
  unsigned slot = (bucket - 15) % 8;
  return (128u + 16u * slot) << row;
}

static bool occupied(const uint32_t* bits, int i) {
  return (bits[i / 32] >> (31 - i % 32)) & 1;
}

static void check_links(void) {
  cmpct_heap_t heap;
  free_t block, left, right, external;
  bool has_left = nondet_bool(), has_right = nondet_bool();
  unsigned size = nondet_uint(), left_size = nondet_uint();
  __CPROVER_assume(size >= sizeof(free_t) && size < (1u << HEAP_ALLOC_VIRTUAL_BITS) && size % NATURAL_ALIGNMENT == 0);
  __CPROVER_assume(left_size <= 0xffff && left_size % NATURAL_ALIGNMENT == 0);
  int bucket = size_to_index_freeing(size - sizeof(header_t));
  unsigned initial_bytes = nondet_uint(), initial_count = nondet_uint();
  __CPROVER_assume(initial_bytes <= UINT32_MAX - size && initial_count < UINT32_MAX);
  heap.remaining = initial_bytes;
  heap.free_blocks = initial_count;
  int probe = nondet_uint() % NUMBER_OF_BUCKETS;
  heap.free_lists[probe] = &external;
  heap.free_lists[bucket] = has_right ? &right : NULL;
  right.prev = NULL;
  unsigned before[BUCKET_WORDS];
  for (int i = 0; i < BUCKET_WORDS; ++i) before[i] = heap.free_list_bits[i] = nondet_uint();
  __CPROVER_assume(occupied(before, bucket) == has_right);

  // All current board call sites ask create_free_area to choose its bucket.
  create_free_area(&heap, &block, left_size, size, NULL);
  __CPROVER_assert(block.header.size_ == (size << 16 | left_size | 1u), "encode the size and tagged left extent");
  __CPROVER_assert(heap.free_lists[bucket] == &block && !block.prev && block.next == (has_right ? &right : NULL) &&
                   (!has_right || right.prev == &block), "prepend the block and restore the reverse link");
  __CPROVER_assert(heap.remaining == initial_bytes + size && heap.free_blocks == initial_count + 1 &&
                   occupied(heap.free_list_bits, probe) == (probe == bucket || occupied(before, probe)),
                   "charge the free block and mark only its bucket occupied");

  // A preceding block exercises interior and tail removal in addition to head removal.
  if (has_left) {
    left.next = &block;
    block.prev = &left;
    heap.free_lists[bucket] = &left;
  }
  unlink_free(&heap, &block, bucket);
  __CPROVER_assert(heap.free_lists[bucket] == (has_left ? &left : has_right ? &right : NULL) &&
                   (!has_left || left.next == (has_right ? &right : NULL)) &&
                   (!has_right || right.prev == (has_left ? &left : NULL)), "splice both neighbors and update the head");
  __CPROVER_assert(heap.remaining == initial_bytes && heap.free_blocks == initial_count &&
                   occupied(heap.free_list_bits, probe) == (probe == bucket ? has_left || has_right : occupied(before, probe)),
                   "remove the exact charge and clear the bucket bit only when empty");
  __CPROVER_assert(probe == bucket || heap.free_lists[probe] == &external, "preserve every other bucket head");

  void* tag = (void*)(uintptr_t)nondet_uint();
  void* payload = create_allocation_header(&block.header, size, left_size | 1u, tag);
  __CPROVER_assert(payload == &block.header + 1 && block.header.tag == tag &&
                   block.header.size_ == ((size << 16) | left_size),
                   "publish the tagged payload and clear the free marker without changing either extent");
}

int main(void) {
  if (nondet_bool()) {
    check_links();
    return 0;
  }
  if (nondet_bool()) {
    size_t bytes = nondet_uint();
    size_t rounded;
    if (nondet_bool()) {
      __CPROVER_assume(bytes != 0 && bytes <= bucket_size(NUMBER_OF_BUCKETS - 1));
      int index = size_to_index_allocating(bytes, &rounded);
      __CPROVER_assert(index >= 0 && index < NUMBER_OF_BUCKETS, "allocate within the bucket table");
      __CPROVER_assert(rounded == bucket_size(index) && rounded >= bytes &&
                       (index == 0 || bucket_size(index - 1) < bytes),
                       "select the smallest bucket that can serve the requested payload");
    } else {
      __CPROVER_assume(bytes >= NATURAL_ALIGNMENT && bytes % NATURAL_ALIGNMENT == 0 &&
                       bytes < bucket_size(NUMBER_OF_BUCKETS));
      int index = size_to_index_freeing(bytes);
      __CPROVER_assert(index >= 0 && index < NUMBER_OF_BUCKETS && bucket_size(index) <= bytes &&
                       bytes < bucket_size(index + 1), "free into the largest bucket lower bound that fits");
    }
    return 0;
  }

  cmpct_heap_t heap;
  uint32_t original[BUCKET_WORDS];
  for (int i = 0; i < BUCKET_WORDS; ++i) original[i] = heap.free_list_bits[i] = nondet_uint();
  int changed = nondet_uint() % NUMBER_OF_BUCKETS;
  bool insert = nondet_bool();
  if (insert) set_free_list_bit(&heap, changed);
  else clear_free_list_bit(&heap, changed);
  int probe = nondet_uint() % (32 * BUCKET_WORDS);
  __CPROVER_assert(occupied(heap.free_list_bits, probe) == (probe == changed ? insert : occupied(original, probe)),
                   "update exactly the selected bitmap bit");
  int start = nondet_int();
  int found = find_nonempty_bucket(&heap, start);
  if (start < 0 || start >= NUMBER_OF_BUCKETS) {
    __CPROVER_assert(found == -1, "reject invalid starting indices");
  } else {
    __CPROVER_assert(found == -1 || (found >= start && found < NUMBER_OF_BUCKETS &&
                     occupied(heap.free_list_bits, found)), "return only an occupied eligible bucket");
    if (probe >= start && probe < NUMBER_OF_BUCKETS && occupied(heap.free_list_bits, probe)) {
      __CPROVER_assert(found >= start && found <= probe, "never skip an earlier occupied eligible bucket");
    }
  }
}
