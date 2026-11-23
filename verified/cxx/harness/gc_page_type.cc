// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "third_party/dartino/gc_metadata.h"
#undef private

using namespace toit;

GcMetadata GcMetadata::singleton_;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword base = nondet_ulong(), end = nondet_ulong(), bits = nondet_ulong();
  CXXV_ASSUME(base < end && base % TOIT_PAGE_SIZE == 0 && end % TOIT_PAGE_SIZE == 0);
  auto& metadata = GcMetadata::singleton_;
  metadata.lowest_address_ = base;
  metadata.heap_extent_ = end - base;
  metadata.heap_start_munged_ = (base / 2) + (uword{1} << (WORD_BIT_SIZE - 1));
  metadata.heap_extent_munged_ = (end - base) / 2;
  bool located = (bits & 1) != 0 && bits >= base && bits < end;
  auto* object = reinterpret_cast<Object*>(bits);
  PageType expected = UNKNOWN_SPACE_PAGE;
  if (located) {
    uword count = (end - base) / TOIT_PAGE_SIZE;
    metadata.page_type_bytes_ = static_cast<uint8*>(malloc(count));
    CXXV_ASSUME(metadata.page_type_bytes_ != nullptr);
    int kind = nondet_int();
    CXXV_ASSUME(kind >= UNKNOWN_SPACE_PAGE && kind <= NEW_SPACE_PAGE);
    expected = static_cast<PageType>(kind);
    metadata.page_type_bytes_[(bits - base) / TOIT_PAGE_SIZE] = kind;
    CXXV_ASSERT(GcMetadata::get_page_type(bits - 1) == expected, "untagged raw address selects its heap page");
  } else {
    // A lookup on any Smi or an outside address must succeed without a table read.
    metadata.page_type_bytes_ = nullptr;
  }
  CXXV_ASSERT(GcMetadata::get_page_type(object) == expected, "arbitrary object word selects the expected page type");
  CXXV_ASSERT(GcMetadata::in_new_or_old_space(object) == (expected != UNKNOWN_SPACE_PAGE),
              "membership requires a located object and a known page type");
}
