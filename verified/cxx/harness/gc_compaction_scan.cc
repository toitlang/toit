// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "third_party/dartino/gc_metadata.cc"

using namespace toit;

enum ScanExit { NEEDS_ROLLBACK, SOURCE_END, ADVANCED };

// The include contains the native forward loop with an observation at
// the return and another at the back edge. A fresh symbolic state represents
// any iteration, independently of how many cards preceded it.
static GcMetadata::Destination scan(GcMetadata::Destination dest, uword& src, uword src_limit,
                                    uint32*& mark_bits, uword*& dest_table, ScanExit& reason) {
#include "compaction_scan.inc"
  reason = NEEDS_ROLLBACK;
  return dest;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(LINE_SIZE == GcMetadata::CARD_SIZE && LINE_SIZE == 32 * WORD_SIZE,
                "one source line contains one mark word");
  uword src = nondet_ulong(), src_limit = nondet_ulong();
  CXXV_ASSUME(src <= src_limit && src % LINE_SIZE == 0 && src_limit % LINE_SIZE == 0);
  uword initial_src = src;
  uword address = nondet_ulong(), limit = nondet_ulong();
  CXXV_ASSUME(address % WORD_SIZE == 0 && limit % WORD_SIZE == 0);
  uint32 marks = nondet_uint();
  unsigned live = 0;
  for (unsigned bit = 0; bit < 32; ++bit) live += (marks >> bit) & 1u;
  bool consume = address <= limit && src < src_limit;
  uword bytes = live * WORD_SIZE;
  CXXV_ASSUME(!consume || bytes <= UINTPTR_MAX - address);
  uword old_entry = nondet_ulong();
  uword entry = old_entry;
  // At source end both pointers may already be one past their tables.
  auto mark = &marks + (src == src_limit);
  auto output = &entry + (src == src_limit);
  auto original_mark = mark;
  auto original_output = output;
  uint32 prior_marks = marks;
  ChunkList chunks;
  GcMetadata::Destination dest(chunks.begin(), address, limit);
  ScanExit reason = NEEDS_ROLLBACK;
  auto after = scan(dest, src, src_limit, mark, output, reason);
  CXXV_ASSERT(reason == (address > limit ? NEEDS_ROLLBACK : consume ? ADVANCED : SOURCE_END),
              "roll back an overshoot even at source end, and scan when the destination is exactly full");
  CXXV_ASSERT(src == initial_src + (consume ? LINE_SIZE : 0) && mark == original_mark + consume &&
              output == original_output + consume && marks == prior_marks,
              "each scan consumes exactly one source card and one entry from each metadata table");
  CXXV_ASSERT(entry == (consume ? address : old_entry) &&
              after.address == address + (consume ? bytes : 0) && after.limit == limit,
              "publish the exclusive cumulative destination and add one word per live bit");
}
