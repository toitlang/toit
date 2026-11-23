// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects.cc"
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef protected
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(PromotedTrack::HEADER_SIZE == 3 * WORD_SIZE, "header, end and next fields");
  uword words[5];
  uword before = nondet_ulong(), payload = nondet_ulong();
  words[0] = before;
  words[4] = payload;
  uword address = reinterpret_cast<uword>(&words[1]);
  CXXV_ASSUME(address % WORD_SIZE == 0 && address <= UINTPTR_MAX - 4 * WORD_SIZE);
  uint8 starts[3] = {11, 12, 13}, dirty[3] = {7, 0, 9};
  GcMetadata::singleton_.starts_bias_ = reinterpret_cast<uword>(&starts[1]) - address / GcMetadata::CARD_SIZE;
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(&dirty[1]) - address / GcMetadata::CARD_SIZE;
  uword previous_header[3];
  auto* previous = static_cast<PromotedTrack*>(HeapObject::from_address(reinterpret_cast<uword>(previous_header)));
  previous->_set_header(Smi::from(PROMOTED_TRACK_CLASS_ID), PROMOTED_TRACK_TAG);
  previous->set_next(nullptr);
  previous->set_end(previous->start());
  auto* next = nondet_bool() ? nullptr : previous;
  uword start = address + 3 * WORD_SIZE, end = address + 4 * WORD_SIZE;
  PromotedTrack* track = PromotedTrack::initialize(next, address, end);
  CXXV_ASSERT(track->_raw() == address && track->class_tag() == PROMOTED_TRACK_TAG &&
              Smi::value(track->class_id()) == PROMOTED_TRACK_CLASS_ID, "publish a correctly tagged track at the supplied address");
  CXXV_ASSERT(track->next() == next && track->start() == start && track->end() == end && track->size() == end - address,
              "expose exactly the payload interval and preserve the successor");
  CXXV_ASSERT(starts[1] == address % 256 && dirty[1] == GcMetadata::NEW_SPACE_POINTERS &&
              starts[0] == 11 && starts[2] == 13 && dirty[0] == 7 && dirty[2] == 9,
              "record the track start and dirty its card only");
  uword used_end = nondet_bool() ? start : end;
  track->set_end(used_end);
  CXXV_ASSERT(track->end() == used_end && track->next() == next && track->start() == start, "flush can trim to an empty or used track");
  track->zap();
  for (unsigned i = 1; i <= 3; ++i) {
    HeapObject* filler = HeapObject::from_address(reinterpret_cast<uword>(&words[i]));
    CXXV_ASSERT(filler->class_tag() == SINGLE_FREE_WORD_TAG && Smi::value(filler->class_id()) == SINGLE_FREE_WORD_CLASS_ID,
                "replace each retired header word with an iterable filler");
  }
  CXXV_ASSERT(previous->class_tag() == PROMOTED_TRACK_TAG && previous->next() == nullptr && previous->end() == previous->start(),
              "preserve the detached successor header");
  CXXV_ASSERT(words[0] == before && words[4] == payload, "retiring the track preserves adjacent storage and promoted payload");
}
