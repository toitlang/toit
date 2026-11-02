// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

POSITIVE ::= 0x4000_0000
NEGATIVE ::= -1_073_741_825

main:
  // These receivers are small integers on a 64-bit compiler but heap integers
  // on a 32-bit VM. Optimization must retain both method implementations.
  [0, 1].do: |mask/int|
    expect-equals (mask == 0 ? 0x8123_4567 : 0x8123_4566) (literal-xor mask)
    expect-equals (mask == 0 ? 0x4000_0000 : 0x4000_0001) (positive-global-xor mask)
    expect-equals (mask == 0 ? -1_073_741_825 : -1_073_741_826) (negative-global-xor mask)
  print "Integer literal width: literal and global dispatch PASS"

literal-xor mask/int:
  return 0x8123_4567 ^ mask

positive-global-xor mask/int:
  return POSITIVE ^ mask

negative-global-xor mask/int:
  return NEGATIVE ^ mask
