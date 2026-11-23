// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "third_party/dartino/object_memory.h"
#pragma push_macro("FATAL")
#undef FATAL
static unsigned fatal_calls;
#define FATAL(...) do { ++fatal_calls; return; } while (false)
#include "third_party/dartino/gc_metadata.h"
#pragma pop_macro("FATAL")
#undef protected
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;
#include "third_party/dartino/object_memory.cc"
static unsigned calls;
static unsigned fail_on;
static uword mapped_start[2];
static uword mapped_size[2];

bool OS::use_virtual_memory(void* address, uword size) {
  CXXV_ASSERT(calls < 2, "at most two metadata commits");
  mapped_start[calls] = reinterpret_cast<uword>(address);
  mapped_size[calls] = size;
  return ++calls != fail_on;
}

static void check_commit(unsigned i, uword base, uword limit, uword first, uword last) {
  // Clip alignment padding before adding it, including near the address-space end.
  constexpr uword granularity = 2 * MB;
  uword down = first % granularity;
  uword up = (0 - last) % granularity;
  uword begin = first - Utils::min(down, first - base);
  uword end = last + Utils::min(up, limit - last);
  CXXV_ASSERT(mapped_start[i] == begin && mapped_size[i] == end - begin &&
              begin <= first && last <= end && base <= begin && end <= limit,
              "cover the required metadata with only the permitted huge-page padding");
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword base = nondet_ulong(), limit = nondet_ulong();
  uword heap_base = nondet_ulong(), heap_end = nondet_ulong();
  CXXV_ASSUME(base != 0 && base < limit && base % TOIT_PAGE_SIZE == 0 && limit % TOIT_PAGE_SIZE == 0);
  CXXV_ASSUME(heap_base < heap_end && heap_base % TOIT_PAGE_SIZE == 0 && heap_end % TOIT_PAGE_SIZE == 0);
  uword extent = heap_end - heap_base;
  uword mark_bytes = extent / (8 * WORD_SIZE);
  uword count_base = nondet_ulong();
  CXXV_ASSUME(mark_bytes <= limit - base && count_base >= base + mark_bytes && count_base < limit &&
              extent / 32 <= limit - count_base);
  auto& meta = GcMetadata::singleton_;
  meta.metadata_ = reinterpret_cast<uint8*>(base);
  meta.metadata_size_ = limit - base;
  meta.mark_bits_bias_ = base - heap_base / (8 * WORD_SIZE);
  meta.cumulative_mark_bits_bias_ = count_base - heap_base / 32;
  uword first = nondet_ulong(), end = nondet_ulong();
  CXXV_ASSUME(heap_base <= first && first < end && end <= heap_end &&
              first % TOIT_PAGE_SIZE == 0 && end % TOIT_PAGE_SIZE == 0);
  meta.lowest_address_ = heap_base;
  meta.heap_extent_ = extent;
  alignas(Chunk) uint8 storage[sizeof(Chunk)];
  Chunk* chunk = ::new (storage) Chunk(nullptr, first, end - first);
  fail_on = nondet_uint();
  GcMetadata::map_metadata_for_chunk(chunk);
  CXXV_ASSERT(calls == (fail_on == 1 ? 1 : 2) && fatal_calls == (fail_on == 1 || fail_on == 2),
              "stop on either failed commit and complete both on success");
  check_commit(0, base, limit, base + (first - heap_base) / (8 * WORD_SIZE),
               base + (end - heap_base) / (8 * WORD_SIZE) + 1);
  if (calls == 2) {
    check_commit(1, base, limit, count_base + (first - heap_base) / 32, count_base + (end - heap_base) / 32);
  }
}
