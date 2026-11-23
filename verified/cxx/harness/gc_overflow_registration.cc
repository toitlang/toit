// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/gc_metadata.cc"
#include "third_party/dartino/object_memory.cc"
#undef private

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword card_size = GcMetadata::CARD_SIZE;
  constexpr uword span = 8 * card_size;
  uword base = nondet_ulong();
  CXXV_ASSUME(base > 0 && base % span == 0 && base <= UINTPTR_MAX - span);
  uint8 bits = nondet_uchar();
  uint8 starts[8];
  for (unsigned i = 0; i < 8; ++i) {
    unsigned offset = nondet_uint() % (card_size / WORD_SIZE);
    starts[i] = static_cast<uint8>(base + i * card_size + offset * WORD_SIZE);
    if ((bits & (1U << i)) == 0 && nondet_bool()) starts[i] = GcMetadata::NO_OBJECT_START;
  }
  GcMetadata::singleton_.starts_bias_ = reinterpret_cast<uword>(starts) - base / card_size;
  GcMetadata::singleton_.overflow_bits_bias_ = reinterpret_cast<uword>(&bits) - base / span;
  uword a = base + (nondet_uint() % (span / WORD_SIZE)) * WORD_SIZE;
  uword b = base + (nondet_uint() % (span / WORD_SIZE)) * WORD_SIZE;
  unsigned witness = nondet_uint() % 8;
  uword card = base + witness * card_size;
  uword earliest = starts[witness] == GcMetadata::NO_OBJECT_START ? card + card_size : card | starts[witness];
  if (card <= a && a < earliest) earliest = a;
  if (card <= b && b < earliest) earliest = b;
  uint8 initial = bits;
  GcMetadata::mark_stack_overflow(HeapObject::from_address(a));
  GcMetadata::mark_stack_overflow(HeapObject::from_address(b));
  bool covers_a = false, covers_b = false;
  unsigned visited = 0;
  scan_overflow_group(&bits, base, [&](uword first, uword limit) {
    CXXV_ASSERT(base < limit && limit <= base + span && limit % card_size == 0 &&
                limit - card_size <= first && first < limit && first % WORD_SIZE == 0,
                "restore a word-aligned traversal interval inside the flagged card");
    unsigned mask = 1U << ((limit - base) / card_size - 1);
    CXXV_ASSERT((visited & mask) == 0, "dispatch each flagged interval once");
    if (limit == card + card_size) {
      CXXV_ASSERT(first == earliest, "resume at the earliest registered start, including earlier work");
    }
    visited |= mask;
    covers_a |= first <= a && a < limit;
    covers_b |= first <= b && b < limit;
  });
  unsigned expected = initial | (1U << ((a - base) / card_size)) | (1U << ((b - base) / card_size));
  CXXV_ASSERT(covers_a && covers_b && visited == expected && bits == 0,
              "recover both discoveries together with all pre-existing flags");
}
