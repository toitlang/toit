// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "process.cc"

using namespace toit;

int main() {
  static_assert(sizeof(word) == sizeof(intptr_t) && WORD_BIT_SIZE == CXXV_WORD_BITS, "counter width");
  word used = nondet_word(), added = nondet_word(), quota = nondet_word();
  word factor = nondet_bool() ? PolicyQuotas::RECEIVER_FACTOR : 1;
  bool admitted = mailbox_has_room(used, added, quota, factor);
  bool expected = false;
  if (used >= 0 && added >= 0) {
    // Two nonnegative signed words sum exactly in one unsigned word.
    uword total = static_cast<uword>(used) + static_cast<uword>(added);
    uword divisor = static_cast<uword>(factor);
    uword needed_quota = total / divisor + (total % divisor != 0);
    expected = total <= static_cast<uword>(INTPTR_MAX) &&
               (quota <= 0 || needed_quota <= static_cast<uword>(quota));
    if (admitted) CXXV_ASSERT(used + added >= used, "admission permits an exact signed counter update");
  }
  CXXV_ASSERT(admitted == expected, "admit exactly representable totals within the scaled quota");
}
