// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/gc_metadata.h"

namespace toit {
class TailMetadata : public GcMetadata {
 public:
  static void initialize_starts_for_chunk(const Chunk*, uword = 0);
  static void initialize_remembered_set_for_chunk(const Chunk*, uword = 0);
};
}
#define GcMetadata TailMetadata
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef GcMetadata
#undef protected
#undef private

using namespace toit;

extern OldSpace space;
static Chunk* entries[2];
static unsigned released[2], regions[2], starts[2], cards[2];

static unsigned index_of(const Chunk* chunk) {
  CXXV_ASSERT(chunk == entries[0] || chunk == entries[1], "operate on a supplied descriptor");
  return chunk == entries[0] ? 0 : 1;
}

Chunk::Chunk(Space* owner, uword first, uword bytes)
    : owner_(owner), start_(first), end_(first + bytes), scavenge_pointer_(first) {}
Chunk::~Chunk() {}

void ObjectMemory::free_chunk(Chunk* chunk) {
  CXXV_ASSERT(chunk->is_not_linked() && chunk->compaction_top() == chunk->start(),
              "release only detached empty chunks");
  ++released[index_of(chunk)];
}

FreeListRegion* FreeListRegion::create_at(uword first, uword size) {
  unsigned i = first < entries[0]->end() ? 0 : 1;
  Chunk* chunk = entries[i];
  CXXV_ASSERT(first == chunk->compaction_top() && first > chunk->start() &&
              first < chunk->usable_end() && size == chunk->usable_end() - first,
              "give the free list exactly the unused payload excluding the sentinel");
  ++regions[i];
  // Represent the header returned by the region encoder in separate storage.
  // The list can chain it when the unused suffix holds all three header words.
  static uword headers[2][3];
  if (size < MINIMUM_SIZE) return nullptr;
  return reinterpret_cast<FreeListRegion*>(HeapObject::from_address(reinterpret_cast<uword>(headers[i])));
}

static void check_cutoff(const Chunk* chunk, uword cutoff) {
  uword last_live = const_cast<Chunk*>(chunk)->compaction_top() - WORD_SIZE;
  CXXV_ASSERT(cutoff % GcMetadata::CARD_SIZE == 0 && last_live < cutoff &&
              cutoff - last_live <= GcMetadata::CARD_SIZE && cutoff <= chunk->end(),
              "retain the final live card and reset from the next boundary");
}

void TailMetadata::initialize_starts_for_chunk(const Chunk* chunk, uword cutoff) {
  check_cutoff(chunk, cutoff);
  ++starts[index_of(chunk)];
}
void TailMetadata::initialize_remembered_set_for_chunk(const Chunk* chunk, uword cutoff) {
  check_cutoff(chunk, cutoff);
  ++cards[index_of(chunk)];
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword split = uword(1) << (WORD_BIT_SIZE - 1);
  uword sizes[2] = {nondet_ulong(), nondet_ulong()};
  for (unsigned i = 0; i < 2; ++i) {
    CXXV_ASSUME(sizes[i] >= TOIT_PAGE_SIZE && sizes[i] <= split - TOIT_PAGE_SIZE &&
                sizes[i] % TOIT_PAGE_SIZE == 0);
  }
  Chunk first(&space, TOIT_PAGE_SIZE, sizes[0]), second(&space, split, sizes[1]);
  entries[0] = &first;
  entries[1] = &second;
  auto* anchor = &space.chunk_list_.anchor_;
  anchor->next_ = anchor->prev_ = anchor;
  bool included[2] = {nondet_bool(), nondet_bool()};
  for (unsigned i = 0; i < 2; ++i) {
    Chunk* chunk = entries[i];
    uword top = nondet_ulong();
    CXXV_ASSUME(chunk->start() <= top && top <= chunk->usable_end() && top % WORD_SIZE == 0);
    chunk->set_compaction_top(top);
    if (included[i]) space.chunk_list_.append(chunk);
  }
  space.mark_chunk_ends_free();
  ChunkList::Element* previous = anchor;
  for (unsigned i = 0; i < 2; ++i) {
    Chunk* chunk = entries[i];
    bool empty = chunk->start() == chunk->compaction_top();
    bool kept = included[i] && !empty;
    CXXV_ASSERT(released[i] == unsigned(included[i] && empty) &&
                regions[i] == unsigned(kept && chunk->compaction_top() < chunk->usable_end()) &&
                starts[i] == unsigned(kept) && cards[i] == unsigned(kept),
                "visit each installed chunk once and restore both tables of each survivor");
    if (kept) {
      CXXV_ASSERT(previous->next_ == chunk && chunk->prev_ == previous, "retain survivors in list order");
      previous = chunk;
    }
  }
  CXXV_ASSERT(previous->next_ == anchor && anchor->prev_ == previous, "close the surviving list");
}
