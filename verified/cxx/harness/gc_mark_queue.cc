// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/gc_metadata.cc"
#undef private

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword raw = nondet_ulong();
  CXXV_ASSUME(raw > 0 && raw % WORD_SIZE == 0 && raw <= UINTPTR_MAX - 2 * WORD_SIZE);
  auto* object = HeapObject::from_address(raw);
  auto& metadata = GcMetadata::singleton_;
  uword card = raw / GcMetadata::CARD_SIZE;

  uint32 bits[] = {nondet_uint(), nondet_uint(), nondet_uint(), nondet_uint()};
  uint32 left = bits[0], before = bits[1], following = bits[2], right = bits[3];
  metadata.mark_bits_bias_ = reinterpret_cast<uword>(&bits[1]) - card * sizeof(uint32);
  unsigned index = (raw / WORD_SIZE) % 32;
  uint32 mask = uint32{1} << index;
  bool was_marked = (before & mask) != 0;
  CXXV_ASSERT(GcMetadata::is_marked(object) == was_marked, "read only the object's first mark bit");
  CXXV_ASSERT(GcMetadata::mark_grey_if_not_marked(object) == was_marked, "queue only previously unmarked objects");
  CXXV_ASSERT(GcMetadata::mark_grey_if_not_marked(object), "a repeated visit sees the mark");
  GcMetadata::mark(object);
  CXXV_ASSERT(bits[0] == left && bits[1] == (before | mask) && bits[2] == following && bits[3] == right,
              "all marking visits preserve every other bit");
  bool second = index == 31 ? (following & 1) != 0 : (before & (mask << 1)) != 0;
  CXXV_ASSERT(GcMetadata::is_grey(object) == !second, "read the second mark across the card boundary when required");

  uint8 overflow[] = {nondet_uchar(), nondet_uchar(), nondet_uchar()};
  uint8 starts[] = {nondet_uchar(), nondet_uchar(), nondet_uchar()};
  uint8 overflow_left = overflow[0], overflow_right = overflow[2], previous_bits = overflow[1];
  uint8 start_left = starts[0], start_right = starts[2];
  uword previous_word = nondet_ulong();
  CXXV_ASSUME(previous_word < GcMetadata::CARD_SIZE / WORD_SIZE);
  uword card_start = raw - raw % GcMetadata::CARD_SIZE;
  uword previous = card_start + previous_word * WORD_SIZE;
  bool empty = nondet_bool();
  starts[1] = empty ? GcMetadata::NO_OBJECT_START : static_cast<uint8>(previous);
  metadata.starts_bias_ = reinterpret_cast<uword>(&starts[1]) - card;
  metadata.overflow_bits_bias_ = reinterpret_cast<uword>(&overflow[1]) - card / 8;
  GcMetadata::mark_stack_overflow(object);
  CXXV_ASSERT(overflow[1] == (previous_bits | (1U << (card % 8))) &&
              overflow[0] == overflow_left && overflow[2] == overflow_right, "flag exactly the overflowing card");
  uword earliest = empty || raw < previous ? raw : previous;
  CXXV_ASSERT((card_start | starts[1]) == earliest && starts[1] != GcMetadata::NO_OBJECT_START &&
              starts[0] == start_left && starts[2] == start_right, "overflow recovery can resume at the earliest recorded object");
}
