// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Exhaustive test of UTF-8 valid bytes.

// Takes 1s to run on desktop in debug mode.

import expect show *

ONE-BYTE-LIMIT ::= 0x7f
TWO-BYTE-LIMIT ::= 0x7ff
THREE-BYTE-LIMIT ::= 0xffff
UNICODE-LIMIT ::= 0x10ffff
SURROGATE-FROM ::= 0xd800
SURROGATE-TO ::= 0xdfff


main:
  0x123456.repeat: | c |
    if c & 0xffff == 0:
      print "0x$(%x c)"
    ba := ByteArray 4: 0
    if c <= ONE-BYTE-LIMIT:
      ba[0] = c
      check true ba
    if c <= TWO-BYTE-LIMIT:
      ba[0] = 0b1100_0000 + (c >> 6)
      ba[1] = 0b1000_0000 + (c & 0b11_1111)
      not-overlong := c > ONE-BYTE-LIMIT
      check not-overlong ba
    if c <= THREE-BYTE-LIMIT:
      ba[0] = 0b1110_0000 + (c >> 12)
      ba[1] = 0b1000_0000 + ((c >> 6) & 0b11_1111)
      ba[2] = 0b1000_0000 + (c & 0b11_1111)
      // The surrogate range is not allowed, and we also check for overlong.
      out-of-range := SURROGATE-FROM <= c <= SURROGATE-TO or c <= TWO-BYTE-LIMIT
      check (not out-of-range) ba
    ba[0] = 0b1111_0000 + (c >> 18)
    ba[1] = 0b1000_0000 + ((c >> 12) & 0b11_1111)
    ba[2] = 0b1000_0000 + ((c >> 6) & 0b11_1111)
    ba[3] = 0b1000_0000 + (c & 0b11_1111)
    // Check for overlong and above Unicode range.
    in-range := THREE-BYTE-LIMIT < c <= UNICODE-LIMIT
    check in-range ba

  // Very out of range 4-byte sequences.
  check false #[0b1111_0101, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  check false #[0b1111_0110, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  check false #[0b1111_0111, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  // 5-byte sequences.
  check false #[0b1111_1000, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  check false #[0b1111_1001, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  check false #[0b1111_1010, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  check false #[0b1111_1011, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  // 6-byte sequences.
  check false #[0b1111_1100, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  check false #[0b1111_1101, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  // 7-byte sequence.
  check false #[0b1111_1110, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111]
  // 8-byte sequence.
  check false #[0b1111_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111, 0b1011_1111]

check expected/bool ba/ByteArray -> none:
  expect (ba.is-valid-string-content) == expected
