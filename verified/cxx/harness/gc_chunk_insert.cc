// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/object_memory_copying.cc"
#undef protected
#undef private

using namespace toit;

// Supply already allocated, disjoint page ranges. Page metadata and physical
// allocation are outside this list-and-accounting check.
Chunk::Chunk(Space* owner, uword start, uword size)
    : owner_(owner), start_(start), end_(start + size), scavenge_pointer_(start) {}
Chunk::~Chunk() {}
void Chunk::set_owner(Space* owner) { owner_ = owner; }

extern OldSpace space;

static constexpr uword REGION_SIZE = uword(1) << (WORD_BIT_SIZE - 2);

static uword extent() {
  uword size = nondet_ulong();
  CXXV_ASSUME(size > 0 && size <= REGION_SIZE && size % TOIT_PAGE_SIZE == 0);
  return size;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  auto anchor = &space.chunk_list_.anchor_;
  anchor->next_ = anchor->prev_ = anchor;
  Chunk first(nullptr, TOIT_PAGE_SIZE, extent());
  Chunk second(nullptr, 2 * REGION_SIZE + TOIT_PAGE_SIZE, extent());
  Chunk added(nullptr, REGION_SIZE + TOIT_PAGE_SIZE, extent());
  bool have_first = nondet_bool();
  bool have_second = nondet_bool();
  if (have_first) space.Space::append(&first);
  if (have_second) space.Space::append(&second);
  space.Space::append(&added);

  unsigned seen = 0;
  uword total = 0;
  Chunk* previous = nullptr;
  for (auto chunk : space.chunk_list_) {
    unsigned id = chunk == &first ? 1 : chunk == &second ? 2 : chunk == &added ? 4 : 0;
    CXXV_ASSERT(id != 0 && (seen & id) == 0, "each linked descriptor was supplied exactly once");
    seen |= id;
    CXXV_ASSERT(chunk->owner() == &space, "the space owns every linked descriptor");
    CXXV_ASSERT(chunk->prev_ == (previous ? static_cast<ChunkList::Element*>(previous) : anchor),
                "the backward link matches the preceding descriptor");
    if (previous) {
      CXXV_ASSERT(previous->size() < chunk->size() ||
                  (previous->size() == chunk->size() && previous->start() < chunk->start()),
                  "chunks are ordered by size and then address");
    }
    total += chunk->size();
    previous = chunk;
  }
  CXXV_ASSERT(anchor->prev_ == previous, "the anchor points back to the final descriptor");
  CXXV_ASSERT(seen == (4u | (have_first ? 1u : 0u) | (have_second ? 2u : 0u)),
              "insertion retains every previous descriptor and publishes the new one");
  CXXV_ASSERT(total == added.size() + (have_first ? first.size() : 0) +
                       (have_second ? second.size() : 0), "the space gains exactly the new extent");
}
