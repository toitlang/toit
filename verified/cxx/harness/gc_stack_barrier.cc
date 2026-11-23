// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/gc_metadata.h"
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword raw = nondet_ulong();
  CXXV_ASSUME(raw != 0 && raw % WORD_SIZE == 0);
  auto* stack = static_cast<Stack*>(HeapObject::from_address(raw));
  uint8 cards[] = {nondet_uchar(), nondet_uchar(), nondet_uchar()};
  uint8 previous = cards[0], initial = cards[1], following = cards[2];
  // Layout supplies one mapped byte per card. Place an arbitrary stack's
  // card in the middle so both neighboring bytes can be observed.
  constexpr uword size = GcMetadata::CARD_SIZE;
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(&cards[1]) - raw / size;
  uword offset = nondet_uint();
  CXXV_ASSUME(offset < size);
  uword address = raw - raw % size + offset;
  CXXV_ASSERT(GcMetadata::is_marked_dirty(address) == (initial != GcMetadata::NO_NEW_SPACE_POINTERS),
              "the lookup observes the original card byte");
  GcMetadata::insert_into_remembered_set(stack);
  CXXV_ASSERT(cards[1] == GcMetadata::NEW_SPACE_POINTERS && GcMetadata::is_marked_dirty(address),
              "the tagged stack dirties the card containing its untagged header");
  CXXV_ASSERT(cards[0] == previous && cards[2] == following, "the barrier preserves adjacent cards");
}
