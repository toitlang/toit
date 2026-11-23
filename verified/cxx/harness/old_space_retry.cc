// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/two_space_heap.cc"
#undef protected
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;
extern ObjectHeap process_heap;
static uword requested;
static uword young_result;
static uword old_result;
static unsigned young_calls;
static unsigned old_calls;

// The reservation proofs for each space supply an aligned address or zero.
uword SemiSpace::allocate(uword size) {
  ++young_calls;
  CXXV_ASSERT(this == &process_heap.two_space_heap_.semi_space_ && size == requested, "reserve in the process semispace");
  return young_result;
}

uword OldSpace::allocate(uword size) {
  ++old_calls;
  CXXV_ASSERT(this == &process_heap.two_space_heap_.old_space_ && size == requested, "retry in the same process old space");
  return old_result;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  TwoSpaceHeap* heap = &process_heap.two_space_heap_;
  heap->process_heap_ = &process_heap;
  bool retry = nondet_bool();
  bool previously_large = nondet_bool();
  heap->large_allocation_failed_ = previously_large;
  process_heap.retrying_primitive_ = retry;
  uint64 total = static_cast<uint64>(nondet_int64());
  heap->total_bytes_allocated_.store(total);
  requested = nondet_ulong();
  CXXV_ASSUME(requested >= WORD_SIZE && requested <= ObjectHeap::max_allocation_size() && requested % WORD_SIZE == 0);
  young_result = reinterpret_cast<uword>(malloc(requested));
  old_result = reinterpret_cast<uword>(malloc(requested));
  CXXV_ASSUME(young_result % WORD_SIZE == 0 && old_result % WORD_SIZE == 0);
  if (nondet_bool()) young_result = 0;
  if (nondet_bool()) old_result = 0;

  // Place the card for the candidate old-space address in an actual table.
  // Neighboring bytes are arbitrary; the allocation may already be dirty.
  uint8 cards[] = {nondet_uchar(), nondet_uchar(), nondet_uchar()};
  uint8 left = cards[0], before = cards[1], right = cards[2];
  GcMetadata::singleton_.remembered_set_bias_ =
      reinterpret_cast<uword>(cards + 1) - old_result / GcMetadata::CARD_SIZE;

  HeapObject* result = heap->allocate(requested);
  bool fallback = young_result == 0 && retry;
  bool promoted = fallback && old_result != 0;
  uword raw = young_result != 0 ? young_result : fallback ? old_result : 0;
  CXXV_ASSERT(young_calls == 1 && old_calls == (fallback ? 1 : 0), "try old space exactly on a primitive retry after a miss");
  CXXV_ASSERT(reinterpret_cast<uword>(result) == (raw == 0 ? 0 : raw + Object::HEAP_TAG), "tag the successful address or return null");
  CXXV_ASSERT(heap->large_allocation_failed_ == (previously_large || (young_result == 0 && requested >= TOIT_PAGE_SIZE / 2)),
              "retain a large semispace miss in the release build");
  CXXV_ASSERT(heap->total_bytes_allocated_.load() == total + (promoted ? requested : 0),
              "charge direct old-space bytes exactly once modulo 2^64");
  CXXV_ASSERT(cards[0] == left && cards[2] == right &&
              cards[1] == (promoted ? GcMetadata::NEW_SPACE_POINTERS : before), "mark only the successful old-space allocation's card");
}
