// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "cmpctmalloc.h"
#include "os_page_extent.h"
#include "arena_types.inc"

struct Layout {
  uintptr_t header, metadata_end, first_page, end;
  intptr_t page_count;
};

// Stop at the first store through the computed address. All arithmetic and
// rejection paths up to that point come from the board's registration function.
static Layout* compute(void* start, size_t size, Layout* result) {
#include "arena_layout.inc"
  *result = {start_int, end_of_struct, start_of_first_page, end_int, pages};
  return result;
}

static uint64_t ceil_multiple(uint64_t value, uint64_t alignment) {
  return ((value + alignment - 1) / alignment) * alignment;
}

static cmpct_heap_t* registered_heap;
static uint64_t lower_start, lower_size, upper_start, upper_size;
static bool saw_lower, saw_upper;

static void add_to_heap(cmpct_heap_t* heap, void* area, size_t bytes, free_t** bucket) {
  CXXV_ASSERT(heap == registered_heap && bucket == nullptr, "give the remainder to the registered heap");
  if (lower_size && uintptr_t(area) == lower_start) {
    CXXV_ASSERT(!saw_lower && bytes == lower_size, "add the exact leading remainder once");
    saw_lower = true;
  } else {
    CXXV_ASSERT(!saw_upper && uintptr_t(area) == upper_start && bytes == upper_size,
                "add the exact trailing remainder once");
    saw_upper = true;
  }
}

static void register_remainders(cmpct_heap_t* page_heap, uintptr_t end_int, uintptr_t end_of_struct,
                                uintptr_t start_of_first_page, intptr_t pages) {
#include "arena_remainders.inc"
}

int main() {
  static_assert(sizeof(uintptr_t) == 4 && sizeof(header_t) == 8 && PAGE_SIZE == 4096, "board ABI");
  uint32_t base = nondet_uint(), bytes = nondet_uint();
  uint64_t end = uint64_t(base) + bytes;
  uint64_t header = ceil_multiple(base, sizeof(header_t));
  uint64_t entries = uint64_t(bytes) / PAGE_SIZE + 1;
  uint64_t metadata_end = ceil_multiple(header + sizeof(cmpct_heap_t) + entries * sizeof(Page), sizeof(header_t));
  uint64_t first_page = ceil_multiple(metadata_end, PAGE_SIZE);
  bool valid = base != 0 && bytes <= INT32_MAX && end <= UINT32_MAX &&
               bytes >= sizeof(cmpct_heap_t) + sizeof(Page) + sizeof(header_t) &&
               metadata_end <= end && first_page <= UINT32_MAX;
  Layout layout;
  Layout* got = compute(reinterpret_cast<void*>(base), bytes, &layout);
  CXXV_ASSERT((got != nullptr) == valid, "accept exactly the representable layouts with room for metadata");
  if (!got) return 0;
  CXXV_ASSERT(layout.header == header && layout.metadata_end == metadata_end &&
              layout.first_page == first_page && layout.end == end,
              "place allocator metadata and the first page at the exact aligned addresses");
  uint64_t count = end > first_page ? (end - first_page) / PAGE_SIZE : 0;
  CXXV_ASSERT(layout.page_count >= 0 && uint64_t(layout.page_count) == count, "count every complete usable page");
  toit::OSPageExtent gc_pages;
  CXXV_ASSERT(toit::OSPageExtent::contained(base, bytes, PAGE_SIZE, &gc_pages),
              "the registered linker interval has a representable GC page range");
  const uint64_t gc_end = uint64_t(gc_pages.start) + gc_pages.size;
  if (count > 0) {
    CXXV_ASSERT(gc_pages.start <= layout.first_page && first_page + count * PAGE_SIZE <= gc_end,
                "the GC range covers the allocator's complete usable page span");
  }
  // Check metadata footprint for board-sized heaps, including the base v5
  // heap. The earlier discovery path rounded the reported bounds outwards.
  if (bytes <= 1024 * 1024 && gc_pages.size > 0) {
    uint64_t previous_start = metadata_end / PAGE_SIZE * PAGE_SIZE;
    uint64_t previous_end = ceil_multiple(end, PAGE_SIZE);
    CXXV_ASSERT(metadata_end < end && previous_start <= gc_pages.start && gc_end <= previous_end,
                "for heaps up to 1 MiB the GC needs no additional metadata pages");
  }
  // The tail registers header-aligned space on either side of the whole pages.
  const uint64_t aligned_end = (end / sizeof(header_t)) * sizeof(header_t);
  lower_start = metadata_end;
  lower_size = (first_page >= end ? aligned_end : first_page) - lower_start;
  upper_start = first_page + count * PAGE_SIZE;
  upper_size = upper_start < end ? aligned_end - upper_start : 0;
  registered_heap = reinterpret_cast<cmpct_heap_t*>(layout.header);
  register_remainders(registered_heap, layout.end, layout.metadata_end, layout.first_page, layout.page_count);
  const size_t minimum = 2 * sizeof(header_t) + sizeof(arena_t) + sizeof(free_t);
  CXXV_ASSERT(saw_lower == (first_page >= end ? lower_size >= minimum : lower_size > minimum) &&
              saw_upper == (upper_size > minimum), "register each qualifying remainder and skip undersized ones");
  if (saw_lower) {
    CXXV_ASSERT(lower_start % sizeof(header_t) == 0 && lower_size % sizeof(header_t) == 0 &&
                lower_size >= minimum && lower_size < PAGE_SIZE &&
                lower_start >= metadata_end && lower_start + lower_size <= first_page &&
                lower_start + lower_size <= end, "lower fragment meets insertion preconditions");
  }
  if (saw_upper) {
    CXXV_ASSERT(upper_start % sizeof(header_t) == 0 && upper_size % sizeof(header_t) == 0 &&
                upper_size >= minimum && upper_size < PAGE_SIZE &&
                upper_start >= first_page + count * PAGE_SIZE && upper_start + upper_size <= end,
                "upper fragment meets insertion preconditions beyond the usable pages");
  }
  uint64_t index = nondet_uint();
  CXXV_ASSUME(index <= count);
  uint64_t entry_end = header + offsetof(cmpct_heap_t, pages) + (index + 1) * sizeof(Page);
  CXXV_ASSERT(entry_end <= layout.metadata_end && entry_end <= end, "all page entries and the sentinel fit");
  if (index < count) {
    uint64_t page = layout.first_page + index * PAGE_SIZE;
    CXXV_ASSERT(page >= layout.metadata_end && page + PAGE_SIZE <= end, "every usable page lies inside the arena");
  }
}
