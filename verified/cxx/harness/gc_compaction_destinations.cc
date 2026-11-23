// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef protected
#undef private

using namespace toit;

extern OldSpace space;
extern Program image;
static Chunk* chunks[2];
static unsigned calls;
static unsigned current;
static uword cursor;
static word empty_source_bytes;
static uword tops[2];

Chunk::Chunk(Space* owner, uword base, uword bytes)
    : owner_(owner), start_(base), end_(base + bytes), scavenge_pointer_(base) {}
Chunk::~Chunk() {}

// Per-source planner contract. It may finish the current destination and move
// to its successor, publishing the completed top before it returns a cursor.
GcMetadata::Destination GcMetadata::calculate_object_destinations(Program* program, Chunk* source,
                                                                  Destination dest) {
  CXXV_ASSERT(calls < 2 && program == &image && chunks[calls] == source,
              "plan sources in list order with the old-space program");
  CXXV_ASSERT(dest.chunk() == chunks[current] && dest.address == cursor &&
              dest.limit == chunks[current]->usable_end(), "resume at the previous destination cursor");
  ++calls;
  bool advance = current == 0 && chunks[1] && nondet_bool();
  if (advance) {
    uword top = nondet_ulong();
    CXXV_ASSUME(cursor <= top && top <= dest.limit && top % WORD_SIZE == 0);
    tops[current] = top;
    dest.chunk()->set_compaction_top(top);
    dest = dest.next_chunk();
    ++current;
  }
  uword next = nondet_ulong();
  CXXV_ASSUME(dest.address <= next && next <= dest.limit && next % WORD_SIZE == 0);
  if (!advance && next == cursor) empty_source_bytes += static_cast<word>(source->size());
  cursor = next;
  dest.address = next;
  return dest;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword quarter = uword(1) << (WORD_BIT_SIZE - 2);
  uword a = nondet_ulong(), b = nondet_ulong();
  CXXV_ASSUME(a > 0 && b > 0 && a < quarter && b < quarter &&
              a % TOIT_PAGE_SIZE == 0 && b % TOIT_PAGE_SIZE == 0);
  Chunk first(&space, TOIT_PAGE_SIZE, a), second(&space, 2 * quarter, b);
  space.program_ = &image;
  auto* anchor = &space.chunk_list_.anchor_;
  anchor->next_ = anchor->prev_ = anchor;
  unsigned count = nondet_uint();
  CXXV_ASSUME(count <= 2);
  if (count >= 1) {
    chunks[0] = &first;
    space.chunk_list_.append(&first);
    cursor = first.start();
  }
  if (count == 2) {
    chunks[1] = &second;
    space.chunk_list_.append(&second);
  }
  first.set_compaction_top(first.end());
  second.set_compaction_top(second.end());
  word reclaimed = space.compute_compaction_destinations();
  CXXV_ASSERT(calls == count, "visit every installed source exactly once");
  word unused_bytes = 0;
  for (unsigned i = 0; i < count; ++i) {
    Chunk* chunk = chunks[i];
    if (i > current) unused_bytes += static_cast<word>(chunk->size());
    uword expected = i < current ? tops[i] : i == current ? cursor : chunk->start();
    CXXV_ASSERT(chunk->compaction_top() == expected && expected >= chunk->start() &&
                expected <= chunk->usable_end() && expected % WORD_SIZE == 0,
                "publish the exact aligned live end of every destination before tail cleanup");
  }
  CXXV_ASSERT(reclaimed == unused_bytes - empty_source_bytes,
              "subtract independently releasable empty sources from unused destination bytes");
}
