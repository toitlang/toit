// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/object_memory_mark_sweep.cc"
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword extent = 2 * TOIT_PAGE_SIZE;
  uword first = nondet_ulong();
  CXXV_ASSUME(first % TOIT_PAGE_SIZE == 0 && first <= UINTPTR_MAX - extent);
  unsigned old_page = nondet_uint() % 2;
  uint8 types[2];
  types[old_page] = OLD_SPACE_PAGE;
  types[1 - old_page] = nondet_bool() ? NEW_SPACE_PAGE : UNKNOWN_SPACE_PAGE;
  auto& meta = GcMetadata::singleton_;
  meta.heap_start_munged_ = (first >> 1) | (uword(1) << (WORD_BIT_SIZE - 1));
  meta.heap_extent_munged_ = extent >> 1;
  meta.page_type_bytes_ = types;

  uword old_base = first + old_page * TOIT_PAGE_SIZE;
  unsigned offset = nondet_uint() % (TOIT_PAGE_SIZE / WORD_SIZE);
  uword source = old_base + offset * WORD_SIZE;
  unsigned bit = offset % 32;
  uint32 marks = nondet_uint() | (uint32(1) << bit);
  uword dest_word = nondet_uint() % (TOIT_PAGE_SIZE / WORD_SIZE - 31);
  uword cumulative = old_base + dest_word * WORD_SIZE;
  uword line = Utils::round_down(source, GcMetadata::CARD_SIZE);
  meta.cumulative_mark_bits_bias_ = reinterpret_cast<uword>(&cumulative) - (line >> GcMetadata::CUMULATIVE_MARK_BITS_SHIFT);
  meta.mark_bits_bias_ = reinterpret_cast<uword>(&marks) - (line >> GcMetadata::MARK_BITS_SHIFT);
  unsigned prior = 0;
  for (unsigned i = 0; i < bit; ++i) prior += (marks >> i) & 1u;
  uword target = cumulative + prior * WORD_SIZE;

  uword other = nondet_ulong();
  // Every immediate, every word-aligned heap reference in the other page,
  // and references outside this mapping may coexist with the old aliases.
  CXXV_ASSUME((other & 1) == 0 ||
              ((other % WORD_SIZE == 1) && (other < old_base || other >= old_base + TOIT_PAGE_SIZE)));
  Object* old = HeapObject::from_address(source);
  Object* unchanged = reinterpret_cast<Object*>(other);
  Object* slots[] = {old, unchanged, old};
  unsigned begin = nondet_uint() % 4;
  unsigned end = nondet_uint() % 4;
  CXXV_ASSUME(begin <= end);
  FixPointersVisitor visitor;
  visitor.FixPointersVisitor::do_roots(slots + begin, end - begin);
  for (unsigned i = 0; i < 3; ++i) {
    Object* expected = i == 1 ? unchanged : begin <= i && i < end ? HeapObject::from_address(target) : old;
    CXXV_ASSERT(slots[i] == expected, "relocate each selected old alias and preserve all other slots");
  }
  CXXV_ASSERT(GcMetadata::get_page_type(HeapObject::from_address(target)) == OLD_SPACE_PAGE,
              "the relocated root remains in the installed old page");
}
