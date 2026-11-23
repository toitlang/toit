// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#ifdef CXXV_ALIGNED_MARK
#undef ALLOW_UNALIGNED_ACCESS
#endif
#include "third_party/dartino/gc_metadata.h"
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;
static HeapObject* requested;
static uword byte_count;
static bool delegated;

void GcMetadata::slow_mark(HeapObject* object, uword size) {
  CXXV_ASSERT(object == requested && size == byte_count && !delegated, "forward the original object and full byte count once");
  delegated = true;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword page = 1U << TOIT_PAGE_SIZE_LOG2;
  constexpr uword metadata_bytes = page / (8 * WORD_SIZE);
  // Vary the mark table's offset within a metadata granule while retaining
  // the natural alignment required by the uint32 mark-word accessors.
  uint32 storage[3 * metadata_bytes / sizeof(uint32)];
  unsigned base_word = nondet_uint();
  CXXV_ASSUME(base_word < metadata_bytes / sizeof(uint32));
  auto* backing = reinterpret_cast<uint8*>(&storage[base_word]);
  unsigned page_word = nondet_uint();
  CXXV_ASSUME(page_word < page / WORD_SIZE);
  uword raw = nondet_ulong();
  CXXV_ASSUME(raw != 0 && raw % page == page_word * WORD_SIZE);
  requested = HeapObject::from_address(raw);
  uword words = nondet_ulong();
  CXXV_ASSUME(words > 0 && words <= (UINTPTR_MAX - raw) / WORD_SIZE);
  byte_count = words * WORD_SIZE;
  uword table = reinterpret_cast<uword>(backing);
  CXXV_ASSUME(table % sizeof(uint32) == 0);
  GcMetadata::singleton_.mark_bits_bias_ = table - (raw - page_word * WORD_SIZE) / (8 * WORD_SIZE);

#ifdef ALLOW_UNALIGNED_ACCESS
  for (unsigned j = 0; j < WORD_SIZE; ++j) backing[page_word / 8 + j] = nondet_uchar();
#else
  storage[base_word + page_word / 32] = nondet_uint();
#endif
  unsigned probe = nondet_uint(), bit = nondet_uint();
  CXXV_ASSUME(probe < 2 * metadata_bytes && bit < 8);
  uint8 before = nondet_uchar();
  backing[probe] = before;
  GcMetadata::mark_all(requested, byte_count);
#ifdef ALLOW_UNALIGNED_ACCESS
  constexpr uword granule = metadata_bytes < 256 ? metadata_bytes : 256;
  bool fits = words <= 8 * WORD_SIZE - 7 && (page_word / 8) % granule + WORD_SIZE < granule;
#else
  bool fits = words <= 32 - page_word % 32;
#endif
  CXXV_ASSERT(delegated == !fits, "select the fitting fast write or the verified range marker");
  if (!delegated) {
    uword position = probe * 8 + bit;
    bool inside = position >= page_word && position - page_word < words;
    CXXV_ASSERT(((backing[probe] >> bit) & 1) == (inside || ((before >> bit) & 1)),
                "mark every covered word and preserve every other bit including the next page");
  }
}
