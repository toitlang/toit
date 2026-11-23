// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/gc_metadata.h"
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(GcMetadata::CARD_SIZE == 32 * WORD_SIZE, "one mark bit per heap word");
  uword line = nondet_ulong(), base = nondet_ulong();
  CXXV_ASSUME(line != 0 && line % GcMetadata::CARD_SIZE == 0 && line <= UINTPTR_MAX - GcMetadata::CARD_SIZE);
  CXXV_ASSUME(base % WORD_SIZE == 0 && base <= UINTPTR_MAX - GcMetadata::CARD_SIZE);
  uint32 marks = nondet_uint();
  uword cumulative = base;
  GcMetadata::singleton_.mark_bits_bias_ = reinterpret_cast<uword>(&marks) - (line >> GcMetadata::MARK_BITS_SHIFT);
  GcMetadata::singleton_.cumulative_mark_bits_bias_ =
      reinterpret_cast<uword>(&cumulative) - (line >> GcMetadata::CUMULATIVE_MARK_BITS_SHIFT);

  // Base case and adjacent positions characterize the exclusive count for
  // every mark pattern, including holes and the first and last word.
  CXXV_ASSERT(GcMetadata::get_destination(HeapObject::from_address(line)) == base,
              "the first word uses the published cumulative destination");
  unsigned bit = nondet_uint();
  CXXV_ASSUME(bit < 31);
  uword address = line + bit * WORD_SIZE;
  uword here = GcMetadata::get_destination(HeapObject::from_address(address));
  uword next = GcMetadata::get_destination(HeapObject::from_address(address + WORD_SIZE));
  CXXV_ASSERT(next == here + (((marks >> bit) & 1u) * WORD_SIZE),
              "advance the destination by one word exactly when the preceding word is live");
}
