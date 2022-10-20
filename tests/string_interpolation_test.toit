// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_interpolate_int
  test_interpolate_utf_8

test_interpolate_int:
  expect_equals "2a" "$(%x 42)"
  expect_equals "02a" "$(%03x 42)"
  expect_equals " 2a" "$(%3x 42)"
  expect_equals "2a " "$(%-3x 42)"
  expect_equals "002a" "$(%04x 42)"
  expect_equals "  2a" "$(%4x 42)"
  expect_equals "2a  " "$(%-4x 42)"
  expect_equals " 2a " "$(%^4x 42)"
  expect_equals "ffffffffffffffff" "$(%x -1)"

  expect_equals "42" "$(%d 42)"
  expect_equals "042" "$(%03d 42)"
  expect_equals " 42" "$(%3d 42)"
  expect_equals "42 " "$(%-3d 42)"
  expect_equals "0042" "$(%04d 42)"
  expect_equals "  42" "$(%4d 42)"
  expect_equals "42  " "$(%-4d 42)"
  expect_equals " 42 " "$(%^4d 42)"
  expect_equals "-1" "$(%d -1)"

  expect_equals "52" "$(%o 42)"
  expect_equals "052" "$(%03o 42)"
  expect_equals " 52" "$(%3o 42)"
  expect_equals "52 " "$(%-3o 42)"
  expect_equals "0052" "$(%04o 42)"
  expect_equals "  52" "$(%4o 42)"
  expect_equals "52  " "$(%-4o 42)"
  expect_equals " 52 " "$(%^4o 42)"
  expect_equals "1777777777777777777777" "$(%o -1)"

  expect_equals "1100111" "$(%b 103)"
  expect_equals "01100111" "$(%08b 103)"
  expect_equals " 1100111" "$(%8b 103)"
  expect_equals "1100111 " "$(%-8b 103)"
  expect_equals "001100111" "$(%09b 103)"
  expect_equals "  1100111" "$(%9b 103)"
  expect_equals "1100111  " "$(%-9b 103)"
  expect_equals " 1100111 " "$(%^9b 103)"
  expect_equals "1111111111111111111111111111111111111111111111111111111111111111" "$(%b -1)"

  36.repeat:
    if it >= 2:
      expect_equals "-1" "$((-1).stringify it)"

test_interpolate_utf_8:
  AS ::= ["A", "Å", "Å", "𐐈"]
  4.repeat:
    x := AS[it]
    expect_equals (it + 1) x.size  // Make sure we test all UTF lengths.
    expect_equals ">$x<" ">$x<"
    expect_equals "> $x<" ">$(%2s x)<"
    expect_equals ">$x <" ">$(%-2s x)<"
    expect_equals "> $x <" ">$(%^3s x)<"

expect_error name [code]:
  expect_equals
    name
    catch code

expect_out_of_bounds [code]:
  expect_error "OUT_OF_BOUNDS" code

expect_invalid_argument [code]:
  expect_error "INVALID_ARGUMENT" code

