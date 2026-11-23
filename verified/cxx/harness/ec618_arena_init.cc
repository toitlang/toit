// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "cmpctmalloc.h"
#include "arena_types.inc"

static cmpct_heap_t* expected_header;
static unsigned clears;
static void check_clear(void* dest, int value, size_t bytes) {
  CXXV_ASSERT(value == 0, "zero the bucket storage");
  if (clears == 0) {
    CXXV_ASSERT(dest == expected_header->free_lists && bytes == sizeof(expected_header->free_lists),
                "clear every free-list bucket");
  } else {
    CXXV_ASSERT(clears == 1 && dest == expected_header->free_list_bits && bytes == sizeof(expected_header->free_list_bits),
                "clear every free-list bitmap word");
  }
  ++clears;
}
#define memset check_clear
#define LTRACE_ENTRY
#include "cmpct_init.inc"
#undef memset

static Page* expected_table;
static size_t expected_count;
static unsigned table_calls;
static void initialize_page_table(Page* table, size_t count) {
  CXXV_ASSERT(table == expected_table && count == expected_count, "initialize exactly the reserved page table");
  ++table_calls;
}

int main() {
  cmpct_heap_t header;
  // The separate layout check establishes the storage extent and count. The
  // VeriFast proof owns the flexible array. Here only the fixed header is live.
  uintptr_t start_int = reinterpret_cast<uintptr_t>(&header);
  uintptr_t end_of_struct = nondet_uint(), end_int = nondet_uint(), start_of_first_page = nondet_uint();
  intptr_t pages = nondet_word();
  CXXV_ASSUME(pages >= 0 && pages <= INT32_MAX / PAGE_SIZE);
  expected_count = pages;
  expected_header = &header;
  expected_table = header.pages;
#include "arena_init.inc"
  CXXV_ASSERT(table_calls == 1 && header.number_of_pages == pages &&
              uintptr_t(header.end_of_heap_structure) == end_of_struct &&
              uintptr_t(header.highest_address) == end_int && uintptr_t(header.page_base) == start_of_first_page,
              "install the supplied heap bounds, page base and count");
  CXXV_ASSERT(header.size == uint64_t(pages) * PAGE_SIZE && header.remaining == header.size &&
              header.allocated_blocks == 0 && header.free_blocks == (pages > 0 ? 1u : 0u),
              "initialize free bytes and block accounting");
  CXXV_ASSERT(!header.lock && !header.ignore_free && header.arenas.previous == &header.arenas &&
              header.arenas.next == &header.arenas, "initialize the arena list and allocator flags");
  CXXV_ASSERT(clears == 2, "initialize both bucket storage ranges");
}
