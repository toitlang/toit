// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/gc_metadata.cc"
#undef private

using namespace toit;

constexpr unsigned WORDS = 96;
alignas(256) static Object* source[WORDS];
static unsigned first_words;
extern Program image;

// The planner may request sizes only at these two live object headers.
word HeapObject::size(Program* program) const {
  uword base = reinterpret_cast<uword>(source);
  CXXV_ASSERT(program == &image && (_raw() == base || _raw() == base + first_words * WORD_SIZE),
              "size reads stay at object boundaries");
  return (_raw() == base ? first_words : WORDS - 1 - first_words) * WORD_SIZE;
}
Chunk::Chunk(Space* owner, uword start, uword bytes)
    : owner_(owner), start_(start), end_(start + bytes), scavenge_pointer_(start) {}
Chunk::~Chunk() {}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword card = GcMetadata::CARD_SIZE;
  static_assert(card == 32 * WORD_SIZE, "one mark word per source card");
  uword base = reinterpret_cast<uword>(source);
  CXXV_ASSUME(base % 256 == 0 && base <= UINTPTR_MAX - sizeof(source));
  first_words = 32 + 1 + nondet_uint() % 15;
  source[0] = source[first_words] = HeapObject::from_address(base);
  uint8 starts[3] = {GcMetadata::NO_OBJECT_START, static_cast<uint8>(base + first_words * WORD_SIZE),
                     GcMetadata::NO_OBJECT_START};
  uint32 marks[3] = {UINT32_MAX, UINT32_MAX, UINT32_MAX >> 1};
  uword counts[3] = {};
  auto& meta = GcMetadata::singleton_;
  meta.starts_bias_ = reinterpret_cast<uword>(starts) - base / card;
  meta.mark_bits_bias_ = reinterpret_cast<uword>(marks) - (base >> GcMetadata::MARK_BITS_SHIFT);
  meta.cumulative_mark_bits_bias_ = reinterpret_cast<uword>(counts) - (base >> GcMetadata::CUMULATIVE_MARK_BITS_SHIFT);

  // Use short card-aligned windows so the destination switches and
  // object walks fit within the model checker's unwind bound.
  Chunk src(nullptr, base, sizeof(source));
  Chunk first(nullptr, 16 * card, 2 * card), skipped(nullptr, 32 * card, card), last(nullptr, 48 * card, 2 * card);
  ChunkList list;
  list.append(&first);
  list.append(&skipped);
  list.append(&last);
  auto dest = GcMetadata::Destination(list.begin(), first.start(), first.usable_end());
  dest = GcMetadata::calculate_object_destinations(&image, &src, dest);
  uword overhang = (first_words - 32) * WORD_SIZE;
  CXXV_ASSERT(first.compaction_top() == first.start() + first_words * WORD_SIZE &&
              skipped.compaction_top() == skipped.start(), "keep the crossing object whole and publish an empty skipped chunk");
  CXXV_ASSERT(dest.chunk() == &last && dest.limit == last.usable_end() &&
              dest.address == last.start() + (WORDS - 1 - first_words) * WORD_SIZE,
              "place the second object in the final destination exactly once");
  CXXV_ASSERT(counts[0] == first.start() && counts[1] == last.start() - overhang &&
              counts[2] == last.start() + card - overhang, "carry the overhang through the skipped destination");
  CXXV_ASSERT(GcMetadata::get_destination(HeapObject::from_address(base)) == first.start() &&
              GcMetadata::get_destination(HeapObject::from_address(base + first_words * WORD_SIZE)) == last.start(),
              "both object headers resolve to their assigned destinations");
  return 0;
}
