// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <stdio.h>
#include "../../../src/reset_reason_ec618.h"

// Compile against the real SDK enum to catch vendor ABI changes. Expected
// values are the public system.power flags, not the vendor's enum ordinals.
int main() {
  struct Case {
    LastResetState_e vendor;
    uint32_t shared;
  };
  const Case cases[] = {
    {LAST_RESET_POR, 1 << 3},
    {LAST_RESET_NORMAL, 1 << 7},
    {LAST_RESET_SWRESET, 1 << 1},
    {LAST_RESET_HARDFAULT, 1 << 12},
    {LAST_RESET_ASSERT, 1 << 12},
    {LAST_RESET_WDTSW, 1 << 4},
    {LAST_RESET_WDTHW, 1 << 4},
    {LAST_RESET_LOCKUP, 1 << 8},
    {LAST_RESET_AONWDT, 1 << 4},
    {LAST_RESET_BATLOW, 1 << 2},
    {LAST_RESET_TEMPHI, 1 << 14},
    {LAST_RESET_FOTA, 1 << 1},
    {LAST_RESET_CPRESET, 1 << 12},
    {LAST_RESET_UNKNOWN, 0},
    {LAST_RESET_MAXNUM, 0},
  };
  for (const auto& test : cases) {
    uint32_t result = toit::ec618_reset_reason_flags(test.vendor);
    if (result != test.shared) {
      fprintf(stderr, "vendor reason %d: got %u, expected %u\n",
              test.vendor, result, test.shared);
      return 1;
    }
  }
  puts("EC618 reset reason conversion PASS");
}
