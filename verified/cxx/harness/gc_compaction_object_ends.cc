// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/gc_metadata.cc"
#undef private

using namespace toit;

alignas(256) static Object* words[64];
static unsigned offsets[3];
extern Program image;

// Supply valid object sizes and check that traversal requests them only at
// the two headers described by the fixture.
word HeapObject::size(Program* program) const {
  CXXV_ASSERT(program == &image, "use the collection program for object sizes");
  uword base = reinterpret_cast<uword>(words);
  if (_raw() == base + offsets[0] * WORD_SIZE) return (offsets[1] - offsets[0]) * WORD_SIZE;
  if (_raw() == base + offsets[1] * WORD_SIZE) return (offsets[2] - offsets[1]) * WORD_SIZE;
  CXXV_ASSERT(false, "read sizes only at a supplied object header");
  return 0;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword line = reinterpret_cast<uword>(words);
  CXXV_ASSUME(line % 256 == 0 && line <= UINTPTR_MAX - sizeof(words));
  offsets[0] = nondet_uint() % 8;
  offsets[1] = 8 + nondet_uint() % 24;
  offsets[2] = 32 + nondet_uint() % 32;
  words[offsets[0]] = words[offsets[1]] = HeapObject::from_address(line);
  bool recorded = nondet_bool(), prefix_live = nondet_bool(), a_live = nondet_bool(), b_live = nondet_bool();
  uint32 prefix = (uint32(1) << offsets[0]) - 1;
  uint32 before_b = (uint32(1) << offsets[1]) - 1;
  uint32 marks = (prefix_live ? prefix : 0) | (a_live ? before_b ^ prefix : 0) | (b_live ? ~before_b : 0);
  uword base = nondet_ulong();
  CXXV_ASSUME(base % WORD_SIZE == 0 && base <= UINTPTR_MAX - sizeof(words));
  uword cumulative = base;
  uint8 start = recorded ? static_cast<uint8>(line + offsets[0] * WORD_SIZE) : GcMetadata::NO_OBJECT_START;
  auto& meta = GcMetadata::singleton_;
  meta.mark_bits_bias_ = reinterpret_cast<uword>(&marks) - (line >> GcMetadata::MARK_BITS_SHIFT);
  meta.cumulative_mark_bits_bias_ = reinterpret_cast<uword>(&cumulative) - (line >> GcMetadata::CUMULATIVE_MARK_BITS_SHIFT);
  meta.starts_bias_ = reinterpret_cast<uword>(&start) - (line >> GcMetadata::CARD_SIZE_LOG_2);

  unsigned limit = nondet_uint() % 65;
  bool output = nondet_bool();
  uword previous = nondet_ulong(), source_end = previous;
  uword result = GcMetadata::end_of_destination_of_last_live_object_starting_before(
      &image, line, line + limit * WORD_SIZE, output ? &source_end : nullptr);
  bool a = recorded && a_live && offsets[0] < limit;
  bool b = recorded && b_live && offsets[1] < limit;
  unsigned moved = (prefix_live ? offsets[0] : 0) + (a ? offsets[1] - offsets[0] : 0) +
                   (b ? offsets[2] - offsets[1] : 0);
  CXXV_ASSERT(result == (a || b ? base + moved * WORD_SIZE : NO_END_FOUND),
              "return the full destination end of the last live object whose header precedes the limit");
  uword end = line + (b ? offsets[2] : offsets[1]) * WORD_SIZE;
  CXXV_ASSERT(source_end == (output && (a || b) ? end : previous),
              "update the optional source end exactly when a live header was found");
}
