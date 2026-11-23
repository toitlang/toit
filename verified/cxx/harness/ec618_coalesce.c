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
static bool expect_fatal;
#define FATAL(reason) do { __CPROVER_assert(expect_fatal, "only a marked block aborts"); __CPROVER_assume(false); } while (0)
#include "buckets.inc"
#include "bucket_links.inc"

static cmpct_heap_t heap;
static header_t *left, *center, *right;
static bool left_free, right_free, held;
static unsigned locks, unlocks, removed, publications;
static size_t expected_left_field, expected_size, original_count;

static void lock(cmpct_heap_t* owner) {
  __CPROVER_assert(owner == &heap && !held, "acquire caller's heap lock once");
  held = true;
  ++locks;
}

static void unlock(cmpct_heap_t* owner) {
  __CPROVER_assert(owner == &heap && held && publications == 1, "unlock after publishing");
  held = false;
  ++unlocks;
}

static void unlink_free_unknown_bucket(cmpct_heap_t* owner, free_t* area) {
  unsigned side = (void*)area == left ? 1 : 2;
  __CPROVER_assert(held && owner == &heap && heap.allocated_blocks == original_count - 1,
                   "unlink under lock after releasing one allocation");
  __CPROVER_assert((side == 1 && left_free) || ((void*)area == right && right_free),
                   "unlink only an adjacent free block");
  __CPROVER_assert(!(removed & side), "each neighbor is unlinked once");
  removed |= side;
}

static void free_memory(cmpct_heap_t* owner, header_t* first, size_t left_field, size_t size) {
  __CPROVER_assert(held && owner == &heap && heap.allocated_blocks == original_count - 1,
                   "publish under lock after releasing one allocation");
  __CPROVER_assert(removed == (unsigned)left_free + 2u * right_free, "all free neighbors unlinked");
  __CPROVER_assert(first == (left_free ? left : center) && left_field == expected_left_field,
                   "merged block retains the outer left boundary");
  __CPROVER_assert(size == expected_size, "merged extent includes exactly the free neighbors");
  __CPROVER_assert(((center->size_ & 1u) != 0) == left_free, "mark the absorbed interior header");
  ++publications;
}
#include "coalesce.inc"

int main(void) {
  // The first and last blocks can be arena sentinels.
  unsigned a = nondet_uint(), b = nondet_uint(), c = nondet_uint();
  __CPROVER_assume(a >= sizeof(header_t) && b >= sizeof(free_t) &&
                   a < 32768 && b < 32768 && c < 32768 &&
                   (a | b | c) % NATURAL_ALIGNMENT == 0 && a + b + c < 32768);
  left_free = nondet_bool();
  right_free = nondet_bool();
  __CPROVER_assume((!left_free || a >= sizeof(free_t)) && (!right_free || c >= sizeof(free_t)));
  char* arena = malloc(a + b + c + sizeof(header_t));
  __CPROVER_assume(arena != NULL);
  left = (header_t*)arena;
  center = (header_t*)(arena + a);
  right = (header_t*)(arena + a + b);
  unsigned prior = nondet_uint() & 0x7ff8u;
  left->size_ = (a << 16) | prior | left_free;
  bool marked = nondet_bool();
  center->size_ = (b << 16) | a | marked;
  right->size_ = (c << 16) | b | right_free;
  expected_left_field = left_free ? prior + 1 : a;
  expected_size = b + (left_free ? a : 0) + (right_free ? c : 0);
  original_count = nondet_uint();
  __CPROVER_assume(original_count > 0);
  heap.allocated_blocks = original_count;
  bool ignored = nondet_bool(), empty = nondet_bool(), locking = nondet_bool();
  heap.ignore_free = ignored ? &heap : NULL;
  void* payload = empty ? NULL : center + 1;
  expect_fatal = marked && !ignored && !empty;
  held = !locking;
  if (locking) cmpct_free(&heap, payload);
  else cmpct_free_already_locked(&heap, payload);
  __CPROVER_assert(!expect_fatal, "free rejects an already marked header");
  unsigned active = !ignored && !empty;
  __CPROVER_assert(publications == active && heap.allocated_blocks == original_count - active,
                   "publish and account for each accepted free once");
  __CPROVER_assert(held == !locking && locks == active * locking && unlocks == locks,
                   "preserve the caller's locking mode");
  return 0;
}
