// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "third_party/dartino/object_memory.h"

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword size = nondet_ulong();
  CXXV_ASSUME(size > 0);
  int leading = Utils::clz(size);
  CXXV_ASSERT(leading >= 0 && leading < WORD_BIT_SIZE, "nonzero word has a leading set bit");
  int bucket = WORD_BIT_SIZE - leading - 1;
  if (bucket >= 12) bucket = 11;
  int expected = 0;
  while (expected < 11 && size >= (uword{2} << expected)) ++expected;
  CXXV_ASSERT(bucket == expected, "leading zero count gives the capped size bucket");
}
