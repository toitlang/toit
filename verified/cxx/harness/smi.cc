// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "constants.h"

using toit::Object;
using toit::Smi;
#include "../annotated/model/smi.c"

static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
static_assert(sizeof(word) == sizeof(long) && sizeof(uword) == sizeof(unsigned long),
              "nondeterministic inputs cover every word");

int main() {
  cxxv::cxxv_constants();
  int64 wide = nondet_int64();
  CXXV_ASSERT(Smi::is_valid(wide) == Smi_is_valid(wide), "Smi::is_valid covers the native tagged range");

  word value = nondet_word();
  if (value >= cxxv::SMI_MIN && value <= cxxv::SMI_MAX) {
    CXXV_ASSERT(Smi::from(value) == Smi_from(value), "Smi::from implements its contract");
  }

  uword bits = nondet_ulong();
  if (bits % 2 == 0) {
    auto object = reinterpret_cast<Object*>(bits);
    auto smi = reinterpret_cast<Smi*>(bits);
    CXXV_ASSERT(Smi::value(object) == Smi_value__Objectp(object), "Smi::value(Object*) implements its contract");
    CXXV_ASSERT(Smi::value(smi) == Smi_value__Smip(smi), "Smi::value(Smi*) implements its contract");
  }
}
