// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "utils.h"

using namespace toit;

static uint32* probe;
static uint32* first_word;
static uword writable_words;

// The VeriFast proof of this specialization establishes these writes for every
// count. Observe its effect on an arbitrary word, including either guard.
template<>
inline void Utils::fill_words<uint32>(uint32* data, uword count, uint32 value) {
  CXXV_ASSERT(data == first_word + 1 && count < writable_words && count > 0,
              "bulk fill stays inside the object's mark words");
  if (data <= probe && probe < data + count) *probe = value;
}

#include "third_party/dartino/gc_metadata.cc"
#undef private

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword raw = nondet_ulong(), words = nondet_ulong();
  CXXV_ASSUME(raw != 0 && raw % WORD_SIZE == 0 && words > 0 && words <= (UINTPTR_MAX - raw) / WORD_SIZE);
  unsigned from = (raw / WORD_SIZE) % 32;
  writable_words = (from + words + 31) / 32;
  uint32* storage = static_cast<uint32*>(malloc((writable_words + 2) * sizeof(uint32)));
  CXXV_ASSUME(storage != nullptr && reinterpret_cast<uword>(storage) % sizeof(uint32) == 0);
  first_word = storage + 1;
  first_word[0] = nondet_uint();
  first_word[writable_words - 1] = nondet_uint();
  uword index = nondet_ulong();
  CXXV_ASSUME(index <= writable_words + 1);
  probe = storage + index;
  uint32 before = nondet_uint();
  *probe = before;
  unsigned bit = nondet_uint();
  CXXV_ASSUME(bit < 32);
  GcMetadata::singleton_.mark_bits_bias_ = reinterpret_cast<uword>(first_word) - raw / GcMetadata::CARD_SIZE * sizeof(uint32);
  bool mark = nondet_bool();
  if (mark) {
    GcMetadata::slow_mark(HeapObject::from_address(raw), words * WORD_SIZE);
  } else {
    Utils::clear_bits(first_word, from, words);
  }
  uword position = index * 32 + bit;
  bool inside = position >= 32 + from && position < 32 + from + words;
  uint32 mask = uint32{1} << bit;
  CXXV_ASSERT(((*probe & mask) != 0) == (inside ? mark : (before & mask) != 0),
              "set or clear exactly the object's bit interval and preserve all other bits");
}
