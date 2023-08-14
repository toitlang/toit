// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-interpolate-int
  test-interpolate-utf-8

test-interpolate-int:
  expect-equals "2a" "$(%x 42)"
  expect-equals "02a" "$(%03x 42)"
  expect-equals " 2a" "$(%3x 42)"
  expect-equals "2a " "$(%-3x 42)"
  expect-equals "002a" "$(%04x 42)"
  expect-equals "  2a" "$(%4x 42)"
  expect-equals "2a  " "$(%-4x 42)"
  expect-equals " 2a " "$(%^4x 42)"
  expect-equals "ffffffffffffffff" "$(%x -1)"

  expect-equals "42" "$(%d 42)"
  expect-equals "042" "$(%03d 42)"
  expect-equals " 42" "$(%3d 42)"
  expect-equals "42 " "$(%-3d 42)"
  expect-equals "0042" "$(%04d 42)"
  expect-equals "  42" "$(%4d 42)"
  expect-equals "42  " "$(%-4d 42)"
  expect-equals " 42 " "$(%^4d 42)"
  expect-equals "-1" "$(%d -1)"

  expect-equals "52" "$(%o 42)"
  expect-equals "052" "$(%03o 42)"
  expect-equals " 52" "$(%3o 42)"
  expect-equals "52 " "$(%-3o 42)"
  expect-equals "0052" "$(%04o 42)"
  expect-equals "  52" "$(%4o 42)"
  expect-equals "52  " "$(%-4o 42)"
  expect-equals " 52 " "$(%^4o 42)"
  expect-equals "1777777777777777777777" "$(%o -1)"

  expect-equals "1100111" "$(%b 103)"
  expect-equals "01100111" "$(%08b 103)"
  expect-equals " 1100111" "$(%8b 103)"
  expect-equals "1100111 " "$(%-8b 103)"
  expect-equals "001100111" "$(%09b 103)"
  expect-equals "  1100111" "$(%9b 103)"
  expect-equals "1100111  " "$(%-9b 103)"
  expect-equals " 1100111 " "$(%^9b 103)"
  expect-equals "1111111111111111111111111111111111111111111111111111111111111111" "$(%b -1)"

  36.repeat:
    if it >= 2:
      expect-equals "-1" "$((-1).stringify it)"

test-interpolate-utf-8:
  AS ::= ["A", "Å", "Å", "𐐈"]
  4.repeat:
    x := AS[it]
    expect-equals (it + 1) x.size  // Make sure we test all UTF lengths.
    expect-equals ">$x<" ">$x<"
    expect-equals "> $x<" ">$(%2s x)<"
    expect-equals ">$x <" ">$(%-2s x)<"
    expect-equals "> $x <" ">$(%^3s x)<"

expect-error name [code]:
  expect-equals
    name
    catch code

expect-out-of-bounds [code]:
  expect-error "OUT_OF_BOUNDS" code

expect-invalid-argument [code]:
  expect-error "INVALID_ARGUMENT" code

