// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef private

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  const uword card = GcMetadata::CARD_SIZE;
  static_assert(GcMetadata::CARD_SIZE == 32 * WORD_SIZE, "one bitmap bit per word");
  uword first = nondet_ulong();
  uword limit = nondet_ulong();
  CXXV_ASSUME(first % card == 0 && limit % card == 0 && first < limit);
  bool has_previous = nondet_bool();
  uint32 previous = has_previous ? nondet_uint() : UINT32_MAX;
  CXXV_ASSUME(previous != 0 && (!has_previous || first >= card));
  uint32 following = nondet_uint();  // Zero denotes the chunk end.
  CXXV_ASSUME(following == 0 || limit <= UINTPTR_MAX - card);

  SweepFreeRegion region = sweep_free_region(first, limit, previous, following);
  CXXV_ASSERT(region.start <= first && first - region.start < card &&
              region.start % WORD_SIZE == 0 && region.end % WORD_SIZE == 0 &&
              region.end >= region.start && region.end - region.start >= FreeListRegion::MINIMUM_SIZE,
              "the free-list header fits in an aligned region");
  unsigned bit = nondet_uint();
  CXXV_ASSUME(bit < 32);
  if (has_previous) {
    uword slot = first - card + bit * WORD_SIZE;
    if (slot >= region.start) CXXV_ASSERT(((previous >> bit) & 1U) == 0, "preceding suffix contains only clear bits");
    if (slot + WORD_SIZE == region.start) CXXV_ASSERT(((previous >> bit) & 1U) != 0, "preceding suffix is maximal");
  } else {
    CXXV_ASSERT(region.start == first, "region starts at the chunk boundary");
  }
  if (following == 0) {
    CXXV_ASSERT(region.end == limit - WORD_SIZE, "reserve exactly the final sentinel word");
  } else {
    uword slot = limit + bit * WORD_SIZE;
    CXXV_ASSERT(region.following_free_words < 32 && region.end == limit + region.following_free_words * WORD_SIZE,
                "stop in the following card at the filler loop start");
    if (!sweep_needs_fill(following, region.following_free_words) && slot >= region.end) {
      CXXV_ASSERT(((following >> bit) & 1U) != 0, "skipping filler writes leaves no unmarked hole after the prefix");
    }
    if (slot < region.end) CXXV_ASSERT(((following >> bit) & 1U) == 0, "following prefix contains only clear bits");
    if (slot == region.end) CXXV_ASSERT(((following >> bit) & 1U) != 0, "the first excluded word is marked");
  }
}
