// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "third_party/dartino/gc_metadata.cc"

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  constexpr uword page = TOIT_PAGE_SIZE_32;
  uword base = nondet_ulong(), size = nondet_ulong();
  CXXV_ASSUME(base % page == 0 && size > 0 && size % page == 0 && size <= UINTPTR_MAX - base);
  uword prefix = internal_ram_metadata_prefix(size);
  CXXV_ASSERT(prefix < size && prefix % page == 0 && prefix <= 108 * KB, "trim only whole pages inside the interval");
  uword retained = size - prefix;
  CXXV_ASSERT((base + prefix) + retained == base + size && base + prefix >= base,
              "retain the original upper bound and a nonempty suffix");
  if (size <= 148 * KB) {
    CXXV_ASSERT(prefix == 0, "small heaps retain every page");
  } else if (size < 256 * KB) {
    CXXV_ASSERT(retained == 148 * KB, "retain the small metadata tier");
  } else if (size < 308 * KB) {
    CXXV_ASSERT(retained == 200 * KB, "retain the medium metadata tier");
  } else {
    CXXV_ASSERT(prefix == 108 * KB, "larger heaps reserve the full C allocation prefix");
  }
}
