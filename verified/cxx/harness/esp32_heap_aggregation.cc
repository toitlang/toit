// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "multi_heap.h"
#include <sys/queue.h>

struct multi_heap_info {
  multi_heap_info_t stats;
  unsigned reads;
};
void multi_heap_get_info(multi_heap_handle_t heap, multi_heap_info_t* out) {
  ++heap->reads;
  *out = heap->stats;
}

struct heap_t_;
static SLIST_HEAD(registered_heap_ll, heap_t_) registered_heaps;
using multi_heap_lock_t = unsigned;
#define FORCE_INLINE_ATTR inline
#define MAX(a, b) ((a) > (b) ? (a) : (b))
// Only address reporting is checked. Byte accounting uses the untagged layout.
#define MULTI_HEAP_BLOCK_OWNER_SIZE() 0
#include "sdk_heap.inc"

static uint32_t lowest, highest;
static unsigned configure(heap_t* node, multi_heap_info* heap, uint32_t requested, bool report_bounds) {
  uint32_t low = nondet_uint(), high = nondet_uint();
  CXXV_ASSUME(low != 0 && high >= low);
  if (report_bounds) {
    heap->stats.lowest_address = reinterpret_cast<void*>(low);
    heap->stats.highest_address = reinterpret_cast<void*>(high);
  }
  bool live = nondet_bool();
  node->heap = live ? heap : nullptr;
  for (unsigned p = 0; p < SOC_MEMORY_TYPE_NO_PRIOS; ++p) node->caps[p] = nondet_uint();
  // Each requested bit must be present at one or more priorities.
  uint32_t absent = ~node->caps[0] & ~node->caps[1] & ~node->caps[2];
  if (!live || (requested & absent) != 0) return 0;
  if (report_bounds) {
    if (lowest == 0 || low < lowest) lowest = low;
    if (high > highest) highest = high;
  }
  return 1;
}

int main() {
  static_assert(SOC_MEMORY_TYPE_NO_PRIOS == 3, "three capability priorities");
  static heap_t first, second;
  static multi_heap_info first_heap, second_heap;
  const uint32_t requested = nondet_uint();
  const bool reports_bounds = nondet_bool();
  unsigned first_reads = 0, second_reads = 0;
  // The first interval may have any ordered extrema. The second node
  // exercises updating those extrema, independently of the number of heaps
  // from which a prefix's extrema were obtained.
  if (nondet_bool()) {
    if (nondet_bool()) {
      second_reads = configure(&second, &second_heap, requested, reports_bounds);
      SLIST_INSERT_HEAD(&registered_heaps, &second, next);
    }
    first_reads = configure(&first, &first_heap, requested, reports_bounds);
    SLIST_INSERT_HEAD(&registered_heaps, &first, next);
  }
  multi_heap_info_t out;
  heap_caps_get_info(&out, requested);
  CXXV_ASSERT(first_heap.reads == first_reads && second_heap.reads == second_reads,
              "query every matching live heap once");
  CXXV_ASSERT(reinterpret_cast<uintptr_t>(out.lowest_address) == lowest,
              "return the minimum reported lower bound across matching heaps");
  CXXV_ASSERT(reinterpret_cast<uintptr_t>(out.highest_address) == highest,
              "return the maximum reported upper bound across matching heaps");
}
