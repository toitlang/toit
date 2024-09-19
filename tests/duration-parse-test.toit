// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

TESTS ::= [
  ["1h", Duration --h=1],
  ["1m", Duration --m=1],
  ["1s", Duration --s=1],
  ["1h3m2s", Duration --h=1 --m=3 --s=2],
  ["1.1s", Duration --s=1 --ms=100],
  ["1.1ms", Duration --ms=1 --us=100],
  ["1ms1ns", Duration --ms=1 --ns=1],
  ["1.1us", Duration --us=1 --ns=100],
  ["1us10ns", Duration --us=1 --ns=10],
  ["-1h", -(Duration --h=1)],
  ["-1m", -(Duration --m=1)],
  ["-1s", -(Duration --s=1)],
  ["-1h3m2s", -(Duration --h=1 --m=3 --s=2)],
  ["-1.1s", -(Duration --s=1 --ms=100)],
  ["-1.1ms", -(Duration --ms=1 --us=100)],
  ["-1ms1ns", -(Duration --ms=1 --ns=1)],
  ["-1.1us", -(Duration --us=1 --ns=100)],
  ["-1us10ns", -(Duration --us=1 --ns=10)],
  ["9999ns", Duration --us=9 --ns=999],
  ["1s3m2h", Duration --s=1 --m=3 --h=2],
  ["1ns1ms", Duration --ns=1 --ms=1],
  ["1us10ns", Duration --us=1 --ns=10],
  [" 1h", Duration --h=1],
  ["1m ", Duration --m=1],
  ["1 h 3 m 2 s ", Duration --h=1 --m=3 --s=2],
  [" - 1 us 1 0 ns", -(Duration --us=1 --ns=10)],
]

DUPLICATE-UNIT ::= "DUPLICATE_UNIT"
MISSING-VALUE ::= "MISSING_VALUE"
INVALID-CHARACTER ::= "INVALID_CHARACTER"

FAILING-TESTS ::= [
  ["1h1h", DUPLICATE-UNIT],
  ["1m1m", DUPLICATE-UNIT],
  ["1s1s", DUPLICATE-UNIT],
  ["1ms1ms", DUPLICATE-UNIT],
  ["1us1us", DUPLICATE-UNIT],
  ["1ns1ns", DUPLICATE-UNIT],
  ["-", MISSING-VALUE],
  ["h", MISSING-VALUE],
  ["m", MISSING-VALUE],
  ["s", MISSING-VALUE],
  ["ms", MISSING-VALUE],
  ["us", MISSING-VALUE],
  ["ns", MISSING-VALUE],
  ["", MISSING-VALUE],
  ["1hm", MISSING-VALUE],
  ["1hs", MISSING-VALUE],
  ["1hms", MISSING-VALUE],
  ["1hus", MISSING-VALUE],
  ["1hns", MISSING-VALUE],
  ["foo", INVALID-CHARACTER],
  ["1n s", MISSING-VALUE],
]

main:
  TESTS.do: | test/List |
    input/string := test[0]
    expected/Duration := test[1]
    actual := Duration.parse input
    expect-equals expected actual

  FAILING-TESTS.do: | test/List |
    input/string := test[0]
    expected := test[1]
    expect-throw expected: Duration.parse input
