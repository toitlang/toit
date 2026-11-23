// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include <limits.h>
#define private public
#include "third_party/dartino/gc_metadata.h"
#undef private

using namespace toit;

Chunk::Chunk(Space* owner, uword start, uword bytes)
    : owner_(owner), start_(start), end_(start + bytes), scavenge_pointer_(start) {}
Chunk::~Chunk() {}

// A source chunk small enough for the planner's signed int displacement.
// Both ends may occur first, even when their addresses exceed INT_MAX.
static void check_overhang() {
  uword end_of_last_source_object_moved = nondet_ulong();
  uword end_of_last_src_line_that_fits = nondet_ulong();
  uword object_end = end_of_last_source_object_moved;
  uword line_end = end_of_last_src_line_that_fits;
  CXXV_ASSUME(object_end % WORD_SIZE == 0 && line_end % GcMetadata::CARD_SIZE == 0);
  uword distance = object_end > line_end ? object_end - line_end : line_end - object_end;
  CXXV_ASSUME(distance <= INT_MAX);
  uword first = nondet_ulong(), limit = nondet_ulong();
  CXXV_ASSUME(first % WORD_SIZE == 0 && first <= limit && (object_end <= line_end || distance <= first));
  ChunkList list;
  GcMetadata::Destination dest(list.begin(), first, limit);
#include "compaction_overhang.inc"
  CXXV_ASSERT(dest.address == (object_end > line_end ? first - distance : first) && dest.limit == limit,
              "subtract only the live suffix extending past the resumed source line");
}

int main() {
  check_overhang();
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword first = nondet_ulong(), next = nondet_ulong();
  uword first_size = nondet_ulong(), next_size = nondet_ulong();
  CXXV_ASSUME(first % TOIT_PAGE_SIZE == 0 && next % TOIT_PAGE_SIZE == 0 &&
              first_size % TOIT_PAGE_SIZE == 0 && next_size % TOIT_PAGE_SIZE == 0 &&
              first_size > 0 && next_size > 0 && first_size <= UINTPTR_MAX - first &&
              next_size <= UINTPTR_MAX - next && (first + first_size <= next || next + next_size <= first));
  Chunk current(nullptr, first, first_size), successor(nullptr, next, next_size);
  ChunkList list;
  list.append(&current);
  list.append(&successor);
  uword address = nondet_ulong();
  CXXV_ASSUME(address % WORD_SIZE == 0 && address <= current.usable_end());
  uword tail = address < first ? first - address : 0;
  CXXV_ASSUME(tail <= next);
  auto dest = GcMetadata::Destination(list.begin(), address, current.usable_end());
  // Native rollback at the first source line, through the jump to restart.
#include "compaction_switch.inc"
restart:
  CXXV_ASSERT(current.compaction_top() == (tail == 0 ? address : first),
              "preserve placed objects or publish an empty destination");
  CXXV_ASSERT(dest.chunk() == &successor && dest.limit == successor.usable_end() &&
              dest.address == next - tail && dest.address % WORD_SIZE == 0,
              "carry exactly the uncounted tail to the successor");
}
