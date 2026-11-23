// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/object_memory.h"
static void reset_starts(void*, int, size_t);
#define memset reset_starts
#include "third_party/dartino/gc_metadata.h"
#undef memset
#include "third_party/dartino/mark_sweep.h"
#undef private

using namespace toit;

extern Chunk chunk;
extern CompactingVisitor visitor;
GcMetadata GcMetadata::singleton_;
static uint8* starts;
static unsigned resets;

static void reset_starts(void* from, int value, size_t count) {
  CXXV_ASSERT(from == starts && count == chunk.size() / GcMetadata::CARD_SIZE &&
              value == GcMetadata::NO_OBJECT_START, "clear every start entry of the selected chunk");
  ++resets;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword first = chunk.start(), end = chunk.end();
  CXXV_ASSUME(first < end && first % TOIT_PAGE_SIZE == 0 && end % TOIT_PAGE_SIZE == 0);
  uword count = (end - first) / GcMetadata::CARD_SIZE;
  starts = static_cast<uint8*>(malloc(count));
  CXXV_ASSUME(starts != nullptr);
  auto& meta = GcMetadata::singleton_;
  meta.starts_bias_ = reinterpret_cast<uword>(starts) - (first >> GcMetadata::CARD_SIZE_LOG_2);

  // Anchor the mark table at its final two cards. A write to any other
  // card is outside this storage and must fail the pointer check.
  uint32 marks[2] = {nondet_uint(), nondet_uint()};
  uint32 previous = marks[0], final = marks[1];
  uword last_line = end - GcMetadata::CARD_SIZE;
  meta.mark_bits_bias_ = reinterpret_cast<uword>(&marks[1]) - (last_line >> GcMetadata::MARK_BITS_SHIFT);
  visitor.CompactingVisitor::chunk_start(&chunk);
  CXXV_ASSERT(resets == 1 && marks[0] == previous && marks[1] == (final | (uint32(1) << 31)),
              "preserve all existing marks and set the final sentinel word live for scanning");
}
