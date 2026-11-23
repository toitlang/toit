// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef protected
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(PromotedTrack::HEADER_SIZE == 3 * WORD_SIZE, "promotion header layout");
  // All word positions in a card occur, independently of the stack layout.
  constexpr int card_words = GcMetadata::CARD_SIZE / WORD_SIZE;
  uword backing[card_words + 3];
  int position = nondet_int();
  CXXV_ASSUME(0 <= position && position < card_words);
  uword* storage = backing + position;
  uword untouched = nondet_ulong();
  storage[3] = untouched;
  uword start = reinterpret_cast<uword>(storage);
  uword payload = start + PromotedTrack::HEADER_SIZE;
  uword end = nondet_ulong();
  CXXV_ASSUME(end > payload && end % WORD_SIZE == 0);
  uword previous[3];
  auto* next = nondet_bool() ? reinterpret_cast<PromotedTrack*>(HeapObject::from_address(reinterpret_cast<uword>(previous))) : nullptr;

  uint8 starts[] = {nondet_uchar(), nondet_uchar(), nondet_uchar(), nondet_uchar()};
  uint8 marks[] = {nondet_uchar(), nondet_uchar(), nondet_uchar()};
  uint8 left = starts[0], adjacent = starts[2], right = starts[3];
  uint8 mark_left = marks[0], mark_right = marks[2];
  GcMetadata::singleton_.starts_bias_ = reinterpret_cast<uword>(&starts[1]) - start / GcMetadata::CARD_SIZE;
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(&marks[1]) - start / GcMetadata::CARD_SIZE;
  auto* track = PromotedTrack::initialize(next, start, end);
  CXXV_ASSERT(reinterpret_cast<uword>(track) == start + Object::HEAP_TAG &&
              track->class_id() == Smi::from(PROMOTED_TRACK_CLASS_ID) && track->has_class_tag(PROMOTED_TRACK_TAG),
              "install a tagged promotion record at the selected address");
  CXXV_ASSERT(track->next() == next && track->end() == end && track->start() == payload &&
              track->size() == end - start && storage[3] == untouched, "track the full interval without writing payload");
  CXXV_ASSERT(starts[1] == start % 256 && starts[2] == adjacent &&
              marks[1] == GcMetadata::NEW_SPACE_POINTERS, "record and dirty the promotion header card");

  GcMetadata::record_start(payload);
  bool same = start / GcMetadata::CARD_SIZE == payload / GcMetadata::CARD_SIZE;
  CXXV_ASSERT(starts[1] == (same ? payload % 256 : start % 256) &&
              starts[2] == (same ? adjacent : payload % 256), "record payload on the same or following card");
  CXXV_ASSERT(starts[0] == left && starts[3] == right && marks[0] == mark_left &&
              marks[2] == mark_right, "preserve surrounding metadata");
}
