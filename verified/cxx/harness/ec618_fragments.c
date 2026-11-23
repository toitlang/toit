// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
bool nondet_bool(void);
#define IRAM_ATTR
#define INLINE inline
#define LTRACE_ENTRY
#define ASSERT(expr) __CPROVER_assert((expr), "allocator precondition holds")
#define FATAL(reason) do { __CPROVER_assert(false, "valid fragment never aborts"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#include "bucket_links.inc"
#define memset __builtin_memset
#include "fragments.inc"

typedef struct {
  arena_t* arena;
  free_t* block;
  unsigned size;
  int bucket;
} fragment_t;

static fragment_t insert(cmpct_heap_t* heap) {
  fragment_t f = {0};
  if (!nondet_bool()) return f;
  unsigned extent = nondet_uint();
  __CPROVER_assume(extent >= arena_overhead + sizeof(free_t) && extent < PAGE_SIZE &&
                   extent % NATURAL_ALIGNMENT == 0);
  f.arena = malloc(extent);
  __CPROVER_assume(f.arena != NULL);
  f.block = (free_t*)((header_t*)(f.arena + 1) + 1);
  f.size = extent - arena_overhead;
  f.bucket = size_to_index_freeing(f.size - sizeof(header_t));
  add_to_heap(heap, f.arena, extent, NULL);
  return f;
}

static void check_headers(fragment_t f) {
  if (!f.arena) return;
  header_t* left = (header_t*)(f.arena + 1);
  header_t* right = (header_t*)((char*)f.block + f.size);
  __CPROVER_assert(left->size_ == sizeof(header_t) << 16 && left->tag == NULL,
                   "the left sentinel points to the free block");
  __CPROVER_assert(f.block->header.size_ == ((f.size << 16) | sizeof(header_t) | 1u),
                   "one free block spans the entire fragment interior");
  __CPROVER_assert(right->size_ == f.size && right->tag == NULL,
                   "the right sentinel points back to the free block");
}

int main(void) {
  cmpct_heap_t heap;
  unsigned pages = nondet_uint();
  __CPROVER_assume(pages <= INT32_MAX / PAGE_SIZE);
  heap.number_of_pages = pages;
  cmpct_init(&heap);
  fragment_t first = insert(&heap), last = insert(&heap);
  check_headers(first);
  check_headers(last);
  arena_t* root = &heap.arenas;
  arena_t* oldest = first.arena ? first.arena : last.arena;
  arena_t* newest = last.arena ? last.arena : first.arena;
  __CPROVER_assert(root->previous == (oldest ? oldest : root) && root->next == (newest ? newest : root),
                   "the arena ring contains exactly the registered fragments");
  if (oldest) {
    __CPROVER_assert(oldest->next == root && newest->previous == root &&
                     oldest->previous == (oldest == newest ? root : newest) &&
                     newest->next == (oldest == newest ? root : oldest), "both directions of the arena ring agree");
  }
  bool shared = first.arena && last.arena && first.bucket == last.bucket;
  if (first.block)
    __CPROVER_assert(first.block->next == NULL && first.block->prev == (shared ? last.block : NULL),
                     "a second insertion retains the first block and repairs its back link");
  if (last.block)
    __CPROVER_assert(last.block->prev == NULL && last.block->next == (shared ? first.block : NULL),
                     "the second block heads its bucket");
  unsigned bucket = nondet_uint();
  __CPROVER_assume(bucket < NUMBER_OF_BUCKETS);
  free_t* head = last.block && bucket == last.bucket ? last.block :
                 first.block && bucket == first.bucket ? first.block : NULL;
  __CPROVER_assert(heap.free_lists[bucket] == head, "every bucket has its expected head");
  unsigned word = nondet_uint();
  __CPROVER_assume(word < BUCKET_WORDS);
  unsigned bits = 0;
  if (first.block && (first.bucket >> 5) == word) bits |= 1u << (31 - (first.bucket & 31));
  if (last.block && (last.bucket >> 5) == word) bits |= 1u << (31 - (last.bucket & 31));
  __CPROVER_assert(heap.free_list_bits[word] == bits, "the entire occupancy bitmap matches the inserted fragments");
  size_t expected = pages * PAGE_SIZE + first.size + last.size;
  __CPROVER_assert(heap.size == expected && heap.remaining == expected && heap.allocated_blocks == 0 &&
                   heap.free_blocks == (unsigned)(pages > 0) + (first.block != NULL) + (last.block != NULL),
                   "account separately for the whole page run and each usable fragment interior");
}
