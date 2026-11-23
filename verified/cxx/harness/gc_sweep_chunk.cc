// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "objects.cc"
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef protected
#undef private

using namespace toit;

extern OldSpace space;
GcMetadata GcMetadata::singleton_;
alignas(256) static uword payload[96];
static uint32 marks[3];
static uint8 starts[3];
static Chunk* installed;
static unsigned releases;

Chunk::Chunk(Space* owner, uword first, uword bytes)
    : owner_(owner), start_(first), end_(first + bytes), scavenge_pointer_(first) {}
Chunk::~Chunk() {}
void ObjectMemory::free_chunk(Chunk* chunk) {
  CXXV_ASSERT(chunk == installed && chunk->is_not_linked(), "unlink the empty chunk before returning it to the provider");
  ++releases;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS && GcMetadata::CARD_SIZE == 32 * WORD_SIZE, "card geometry");
  // Three cards expose both boundaries of a complete run of empty cards.
  uword base = reinterpret_cast<uword>(payload);
  CXXV_ASSUME(base % GcMetadata::CARD_SIZE == 0 && base <= UINTPTR_MAX - sizeof(payload));
  Chunk chunk(&space, base, sizeof(payload));
  installed = &chunk;
  auto* anchor = &space.chunk_list_.anchor_;
  anchor->prev_ = anchor->next_ = anchor;
  space.chunk_list_.append(&chunk);

  bool left = nondet_bool(), right = nondet_bool();
  uint32 prefix = left ? (nondet_uint() & 0x7fffu) | 0x8000u : 0;
  uint32 suffix = right ? (nondet_uint() & 0x3ffe0000u) | 0x40010000u : 0;
  marks[0] = prefix;
  marks[2] = suffix;
  auto& meta = GcMetadata::singleton_;
  meta.mark_bits_bias_ = reinterpret_cast<uword>(marks) - (base >> GcMetadata::MARK_BITS_SHIFT);
  meta.starts_bias_ = reinterpret_cast<uword>(starts) - base / GcMetadata::CARD_SIZE;
  starts[0] = starts[1] = starts[2] = 0;
  unsigned i = nondet_uint() % 96;
  uword before = nondet_ulong();
  payload[i] = before;
  unsigned bucket = nondet_uint() % FreeList::NUMBER_OF_BUCKETS;
  space.free_list_.buckets_[bucket] = reinterpret_cast<FreeListRegion*>(HeapObject::from_address(base));
  uword used = space.sweep();
  CXXV_ASSERT(used == static_cast<uword>(__builtin_popcount(prefix) + __builtin_popcount(suffix)) * WORD_SIZE,
              "count exactly the marked payload bytes");
  if (!left && !right) {
    CXXV_ASSERT(releases == 1 && space.chunk_list_.is_empty() && space.free_list_.buckets_[bucket] == nullptr,
                "release an entirely empty chunk and discard stale free-list entries");
    return 0;
  }
  CXXV_ASSERT(releases == 0 && space.chunk_list_.first() == &chunk && space.chunk_list_.last() == &chunk,
              "retain the chunk containing live words");
  unsigned lo = left ? 16 : 0;
  unsigned hi = right ? 80 : 95;
  uword bytes = (hi - lo) * WORD_SIZE;
  auto* region = reinterpret_cast<FreeListRegion*>(HeapObject::from_address(base + lo * WORD_SIZE));
  CXXV_ASSERT(region->has_class_tag(FREE_LIST_REGION_TAG) && region->size() == bytes && region->next_region() == nullptr,
              "encode exactly the coalesced gap as a detached free-list region");
  bool match = (uword(1) << bucket) <= bytes && bytes < (uword(2) << bucket);
  CXXV_ASSERT(space.free_list_.buckets_[bucket] == (match ? region : nullptr),
              "install only the coalesced region in its size bucket");
  CXXV_ASSERT(!left || starts[0] == static_cast<uint8>(base + lo * WORD_SIZE),
              "repair the preceding card start when the gap extends into it");
  CXXV_ASSERT(starts[1] == GcMetadata::NO_OBJECT_START &&
              starts[2] == (right ? static_cast<uint8>(base + hi * WORD_SIZE) : GcMetadata::NO_OBJECT_START),
              "clear empty starts and record the first live word after the gap");
  CXXV_ASSERT(payload[95] == 0 && marks[0] == 0 && marks[1] == 0 && marks[2] == 0,
              "restore the sentinel and clear the consumed mark table");
  if (i < lo || (i >= hi && i < 95)) {
    uint32 bits = i < lo ? prefix : suffix;
    bool live = ((bits >> (i % 32)) & 1u) != 0;
    CXXV_ASSERT(payload[i] == (live ? before : reinterpret_cast<uword>(FreeListRegion::single_free_word_header())),
                "preserve live words and replace every isolated dead word with an iterable filler");
  }
  return 0;
}
