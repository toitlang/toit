// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "third_party/dartino/object_memory.cc"

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword first = nondet_ulong();
  constexpr unsigned span = 8 * GcMetadata::CARD_SIZE;
  CXXV_ASSUME(first % span == 0 && first <= UINTPTR_MAX - span);
  uint8 bytes[] = {nondet_uchar(), nondet_uchar(), nondet_uchar()};
  uint8 left = bytes[0], initial = bytes[1], right = bytes[2];
  unsigned witness = nondet_uint();
  CXXV_ASSUME(witness < 8);
  unsigned mask = 1U << witness;
  bool due = (initial & mask) != 0;
  bool deferred = false;
  bool visited = false;
  int previous = -1;

  scan_overflow_byte(&bytes[1], first, [&](uword card) {
    CXXV_ASSERT(card >= first && card < first + span && card % GcMetadata::CARD_SIZE == 0,
                "callback receives an aligned card in this metadata byte");
    int index = (card - first) / GcMetadata::CARD_SIZE;
    CXXV_ASSERT(previous < index, "visit each selected card once in ascending address order");
    previous = index;
    CXXV_ASSERT((bytes[1] & (1U << index)) == 0, "clear the selected bit before tracing the card");
    if (static_cast<unsigned>(index) == witness) visited = true;
    // Traversal may overflow on any subset of cards, including the current one.
    uint8 raised = nondet_uchar();
    bytes[1] |= raised;
    if ((raised & mask) != 0) {
      if (static_cast<unsigned>(index) < witness) due = true;
      else deferred = true;
    }
  });
  CXXV_ASSERT(visited == due, "visit all and only originally flagged or newly flagged upcoming cards");
  CXXV_ASSERT(((bytes[1] & mask) != 0) == deferred, "retain work raised on a current or earlier card");
  CXXV_ASSERT(bytes[0] == left && bytes[2] == right, "preserve adjacent overflow bytes");
}
