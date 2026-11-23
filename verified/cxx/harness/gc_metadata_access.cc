// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/gc_metadata.cc"
#undef private

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword first = nondet_ulong(), extent = nondet_ulong(), offset = nondet_ulong();
  CXXV_ASSUME(first % TOIT_PAGE_SIZE == 0 && extent % TOIT_PAGE_SIZE == 0 &&
              extent <= UINTPTR_MAX - first && offset < extent);
  uword address = first + offset;
  uword card = offset / GcMetadata::CARD_SIZE;
  uword marks = nondet_ulong(), counts = nondet_ulong(), starts = nondet_ulong();
  uword remembered = nondet_ulong(), overflow = nondet_ulong();
  CXXV_ASSUME(marks % WORD_SIZE == 0 && counts % WORD_SIZE == 0);
  CXXV_ASSUME(extent / (8 * WORD_SIZE) <= UINTPTR_MAX - marks && extent / 32 <= UINTPTR_MAX - counts &&
              extent / GcMetadata::CARD_SIZE <= UINTPTR_MAX - remembered &&
              extent / GcMetadata::CARD_SIZE <= UINTPTR_MAX - starts &&
              extent / (8 * GcMetadata::CARD_SIZE) <= UINTPTR_MAX - overflow);
  auto& meta = GcMetadata::singleton_;
  meta.lowest_address_ = first;
  meta.heap_extent_ = extent;
  meta.mark_bits_bias_ = marks - first / (8 * WORD_SIZE);
  meta.cumulative_mark_bits_bias_ = counts - first / 32;
  meta.starts_bias_ = starts - first / GcMetadata::CARD_SIZE;
  meta.remembered_set_bias_ = remembered - first / GcMetadata::CARD_SIZE;
  meta.overflow_bits_bias_ = overflow - first / (8 * GcMetadata::CARD_SIZE);
  CXXV_ASSERT(reinterpret_cast<uword>(GcMetadata::mark_bits_for(address)) == marks + card * sizeof(uint32) &&
              (card + 1) * sizeof(uint32) <= extent / (8 * WORD_SIZE), "select the covered mark word");
  CXXV_ASSERT(reinterpret_cast<uword>(GcMetadata::cumulative_mark_bits_for(address)) == counts + card * WORD_SIZE &&
              (card + 1) * WORD_SIZE <= extent / 32, "select the covered destination word");
  CXXV_ASSERT(reinterpret_cast<uword>(GcMetadata::starts_for(address)) == starts + card &&
              reinterpret_cast<uword>(GcMetadata::remembered_set_for(address)) == remembered + card &&
              card < extent / GcMetadata::CARD_SIZE, "index both card tables");
  CXXV_ASSERT(reinterpret_cast<uword>(GcMetadata::overflow_bits_for(address)) == overflow + card / 8 &&
              card / 8 < extent / (8 * GcMetadata::CARD_SIZE), "index the overflow byte for the card");
  CXXV_ASSERT(offset / TOIT_PAGE_SIZE < extent / TOIT_PAGE_SIZE, "the page index fits the installed page-type table");

  // Back this card's entry with one physical byte. The allocator publishes
  // the low address byte, which the compaction planner decodes from the line.
  uint8 entry = GcMetadata::NO_OBJECT_START;
  uword line = first + card * GcMetadata::CARD_SIZE;
  uword header = Utils::round_down(address, WORD_SIZE);
  meta.starts_bias_ = reinterpret_cast<uword>(&entry) - line / GcMetadata::CARD_SIZE;
  GcMetadata::record_start(header);
  CXXV_ASSERT(entry != GcMetadata::NO_OBJECT_START &&
              GcMetadata::object_address_from_start(line, entry) == header,
              "recover the exact published object header in every covered card");
}
