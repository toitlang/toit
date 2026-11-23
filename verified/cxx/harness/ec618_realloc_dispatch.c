// Copyright (C) 2026 Toit contributors.

#include <stdbool.h>
#include <stdint.h>
#include "cmpctmalloc.h"
#include "arena_types.inc"

unsigned nondet_uint(void);
bool nondet_bool(void);
static cmpct_heap_t heap;
static header_t old_header;
static char replacement, moved;
static void *old_payload, *fresh, *page_result, *thread_tag;
static size_t request, usable;
static bool page, released;
static unsigned allocations, queries, copies, classifications, locks, retries, unlocks, tag_reads;

void* cmpct_malloc_impl(cmpct_heap_t* h, size_t n) {
  __CPROVER_assert(h == &heap && n == request && n != 0 && !allocations,
                   "try one replacement of the requested size");
  ++allocations;
  return fresh;
}
size_t cmpct_get_allocated_size_impl(cmpct_heap_t* h, void* p) {
  __CPROVER_assert(h == &heap && p == old_payload && p && allocations == 1 && !released,
                   "measure the live source after trying allocation");
  ++queries;
  return usable;
}
static void* copy_payload(void* dest, const void* src, size_t n) {
  __CPROVER_assert(dest == fresh && fresh && src == old_payload && src && dest != src &&
                   !released && queries == 1, "copy between distinct live allocations");
  __CPROVER_assert(n <= usable && n <= request && (n == usable || n == request),
                   "preserve exactly the common prefix of the two extents");
  ++copies;
  return dest;
}
void cmpct_free_impl(cmpct_heap_t* h, void* p) {
  __CPROVER_assert(h == &heap && p == old_payload && !released &&
                   (request == 0 || copies == 1), "release the original once on zero size or after copying");
  released = true;
}
static bool is_page_allocated(cmpct_heap_t* h, void* p) {
  __CPROVER_assert(h == &heap && p == old_payload && p && !fresh && !released && queries == 1,
                   "classify the live source only after replacement fails");
  ++classifications;
  return page;
}
static void lock(cmpct_heap_t* h) {
  __CPROVER_assert(h == &heap && classifications == 1 && !locks, "lock the selected fallback once");
  ++locks;
}
static void* realloc_page_allocation(cmpct_heap_t* h, void* p, size_t n, size_t bytes) {
  __CPROVER_assert(h == &heap && p == old_payload && n == request && bytes == usable &&
                   locks == 1 && !unlocks && !released, "resize the original page extent under lock");
  ++retries;
  return page_result;
}
static void unlock(cmpct_heap_t* h) {
  __CPROVER_assert(h == &heap && locks == 1 && (page ? retries == 1 : tag_reads == 1), "unlock after resize or retag");
  ++unlocks;
}
static void* get_tag(void) {
  __CPROVER_assert(locks == 1 && !unlocks, "read the small allocation tag under lock");
  ++tag_reads;
  return thread_tag;
}
#define IRAM_ATTR
#define GET_THREAD_LOCAL_TAG get_tag()
#define memcpy copy_payload
#include "realloc_dispatch.inc"

int main(void) {
  old_payload = nondet_bool() ? &old_header + 1 : NULL;
  fresh = nondet_bool() ? &replacement : NULL;
  request = nondet_uint();
  usable = nondet_uint();
  page = nondet_bool();
  if (!page) __CPROVER_assume(usable < (1u << HEAP_ALLOC_VIRTUAL_BITS));
  page_result = nondet_bool() ? NULL : nondet_bool() ? old_payload : (void*)&moved;
  void* initial_tag = old_header.tag = (void*)(uintptr_t)nondet_uint();
  unsigned packed = old_header.size_ = nondet_uint();
  thread_tag = (void*)(uintptr_t)nondet_uint();

  bool measure = request != 0 && old_payload != NULL;
  bool copy = measure && fresh;
  bool fallback = measure && !fresh;
  bool retry = fallback && page;
  bool retain = fallback && !page && request <= usable &&
                3 * ((uint64_t)request + sizeof(free_t)) > 4 * (uint64_t)usable;
  void* expected = !request ? NULL : !fallback ? fresh : retry ? page_result : retain ? old_payload : NULL;
  void* result = cmpct_realloc_impl(&heap, old_payload, request);
  __CPROVER_assert(result == expected && allocations == (unsigned)(request != 0) &&
                   queries == measure && classifications == fallback, "propagate the selected resize outcome");
  __CPROVER_assert(copies == copy && released == (!request || copy),
                   "failure preserves ownership and replacement releases only after the copy");
  __CPROVER_assert(retries == retry && locks == (retry || retain) && unlocks == locks, "balance the page resize or retained block lock");
  __CPROVER_assert(tag_reads == retain && old_header.tag == (retain ? thread_tag : initial_tag) &&
                   old_header.size_ == packed, "retag a retained small block without changing its boundary sizes");
}
