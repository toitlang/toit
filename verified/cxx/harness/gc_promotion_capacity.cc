// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "third_party/dartino/object_memory_mark_sweep.cc"

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword size = nondet_ulong();
  uword preferred = nondet_ulong();
  word limit = nondet_word();
  bool tracking = nondet_bool();
  uword chunk = promotion_chunk_size(size, tracking, preferred, limit);
  // The old-space installer writes a sentinel at the end, and a promotion
  // header before the payload when tracking. Compute the oracle in pages.
  uword overhead = WORD_SIZE + (tracking ? PromotedTrack::header_size() : 0);
  uword pages = limit > 0 ? static_cast<uword>(limit) / TOIT_PAGE_SIZE : 0;
  uword capacity = pages * TOIT_PAGE_SIZE;
  bool fits = capacity >= overhead && size <= capacity - overhead;
  CXXV_ASSERT((chunk != 0) == fits, "accept exactly the requests that fit in whole pages under the expansion limit");
  if (!fits) return 0;
  uword needed = size + overhead;
  uword required_pages = needed / TOIT_PAGE_SIZE + (needed % TOIT_PAGE_SIZE != 0);
  uword preferred_pages = preferred / TOIT_PAGE_SIZE;
  if (preferred_pages > pages) preferred_pages = pages;
  uword selected_pages = required_pages > preferred_pages ? required_pages : preferred_pages;
  CXXV_ASSERT(chunk == selected_pages * TOIT_PAGE_SIZE && chunk <= capacity && chunk >= needed,
              "return the requested page count with space for the installed header and sentinel");
}
