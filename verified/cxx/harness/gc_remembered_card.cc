// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/object_memory.h"
static void* clear_cards(void*, int, size_t);
#define memset clear_cards
#include "third_party/dartino/gc_metadata.h"
#undef memset
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;
extern Chunk chunk;
static uint8* cards;
static uword witness, expected_first, expected_end;
static unsigned clears;

// libc writes each byte of the requested interval. Observe one arbitrary
// table byte, checking the complete destination and extent on every call.
static void* clear_cards(void* dst, int value, size_t count) {
  ++clears;
  CXXV_ASSERT(dst == cards + expected_first && count == expected_end - expected_first &&
              value == GcMetadata::NO_NEW_SPACE_POINTERS, "clear exactly the unused card interval");
  if (witness >= expected_first && witness < expected_end) cards[witness] = value;
  return dst;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword card_size = GcMetadata::CARD_SIZE;
  uword first = nondet_ulong(), extent = nondet_ulong();
  CXXV_ASSUME(first % TOIT_PAGE_SIZE == 0 && extent % TOIT_PAGE_SIZE == 0 &&
              extent > 0 && extent <= UINTPTR_MAX - first);
  // Chunk bounds and the two published table fields follow the setup and
  // page-provider contracts. The observed card may be outside this chunk.
  uword lo = chunk.start(), hi = chunk.end();
  CXXV_ASSUME(first <= lo && lo < hi && hi <= first + extent &&
              lo % TOIT_PAGE_SIZE == 0 && hi % TOIT_PAGE_SIZE == 0);
  cards = static_cast<uint8*>(malloc(extent / card_size));
  CXXV_ASSUME(cards != nullptr);
  GcMetadata::singleton_.remembered_set_ = cards;
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(cards) - first / card_size;
  uword offset = nondet_ulong();
  CXXV_ASSUME(offset < extent);
  uword address = first + offset;
  witness = offset / card_size;
  uint8 original = nondet_uchar();
  cards[witness] = original;
  uword marked = nondet_ulong();
  CXXV_ASSUME(lo <= marked && marked < hi);
  // Primitive retries mark a raw address. Mutating VM objects and restoring
  // stacks pass the corresponding tagged pointer to the same template.
  HeapObject* object = HeapObject::from_address(Utils::round_down(marked, WORD_SIZE));
  switch (nondet_uint() % 4) {
    case 0: GcMetadata::insert_into_remembered_set(marked); break;
    case 1: GcMetadata::insert_into_remembered_set(reinterpret_cast<Array*>(object)); break;
    case 2: GcMetadata::insert_into_remembered_set(reinterpret_cast<Instance*>(object)); break;
    case 3: GcMetadata::insert_into_remembered_set(reinterpret_cast<Stack*>(object)); break;
  }
  bool same_card = (marked - first) / card_size == witness;
  uint8 before_clear = same_card ? GcMetadata::NEW_SPACE_POINTERS : original;
  CXXV_ASSERT(cards[witness] == before_clear, "change only the card containing the marked address");

  // Compaction passes the first unused word, rounded up so the card
  // containing the final live word stays intact. New ownership clears all.
  uword live_end = nondet_ulong();
  CXXV_ASSUME(lo <= live_end && live_end <= chunk.usable_end() && live_end % WORD_SIZE == 0);
  bool new_owner = nondet_bool();
  uword cutoff = new_owner ? 0 : Utils::round_up(live_end, card_size);
  expected_first = new_owner ? (lo - first) / card_size :
                   (live_end - first + card_size - 1) / card_size;
  expected_end = (hi - first) / card_size;
  GcMetadata::initialize_remembered_set_for_chunk(&chunk, cutoff);
  CXXV_ASSERT(clears == (expected_first < expected_end ? 1u : 0u),
              "skip the reset when the final live word occupies the last card");
  bool cleared = expected_first <= witness && witness < expected_end;
  uint8 expected = cleared ? GcMetadata::NO_NEW_SPACE_POINTERS : before_clear;
  CXXV_ASSERT(cards[witness] == expected && GcMetadata::is_marked_dirty(address) == (expected != 0),
              "retain live and neighboring cards and clear every unused card");
}
