// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "objects.cc"
#undef private

using namespace toit;

int main() {
  static_assert(FREE_LIST_REGION_TAG == 9, "region storage proof tag");
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(FreeListRegion::MINIMUM_SIZE == 3 * WORD_SIZE, "chainable header size");

  // Only the three header words are accessible to the implementation, even
  // when the supplied extent describes a much larger region.
  uword words[3];
  uword before[3];
  for (int i = 0; i < 3; ++i) words[i] = before[i] = nondet_ulong();
  uword size = nondet_ulong();
  CXXV_ASSUME(size % WORD_SIZE == 0);
  uword start = reinterpret_cast<uword>(words);
  FreeListRegion* region = FreeListRegion::create_at(start, size);
  if (size < FreeListRegion::MINIMUM_SIZE) {
    CXXV_ASSERT(region == nullptr, "undersized region is omitted");
    for (int i = 0; i < 3; ++i) {
      if (static_cast<uword>(i * WORD_SIZE) < size) {
        auto* filler = static_cast<FreeListRegion*>(HeapObject::from_address(start + i * WORD_SIZE));
        CXXV_ASSERT(filler->has_class_tag(SINGLE_FREE_WORD_TAG) && filler->size() == WORD_SIZE,
                    "one walkable filler per supplied word");
      } else {
        CXXV_ASSERT(words[i] == before[i], "leave words beyond the supplied extent intact");
      }
    }
  } else {
    CXXV_ASSERT(region == reinterpret_cast<FreeListRegion*>(start + 1) && reinterpret_cast<uword>(region) == start + 1,
                "return the region pointer at the tagged start");
    CXXV_ASSERT(region->has_class_tag(FREE_LIST_REGION_TAG) && region->size() == size &&
                region->next_region() == nullptr, "initialize detached region with exact extent");
    uword other[3];
    auto* next = FreeListRegion::create_at(reinterpret_cast<uword>(other), sizeof(other));
    region->set_next_region(next);
    CXXV_ASSERT(region->next_region() == next && region->size() == size &&
                region->has_class_tag(FREE_LIST_REGION_TAG), "link without changing extent or tag");
    region->set_next_region(nullptr);
    CXXV_ASSERT(region->next_region() == nullptr && region->size() == size &&
                region->has_class_tag(FREE_LIST_REGION_TAG), "detach without changing extent or tag");
  }
}
