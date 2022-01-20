// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.maskint show *

class Test:
  i/int ::= ?
  size/int ::= ?

  constructor .i .size:

positive_integer_tests/List ::= [
    Test ((1 << 0) - 1) 1,
    Test ((1 << 0)) 1,
    Test ((1 << 0) + 1) 1,

    Test ((1 << 1) - 1) 1,
    Test ((1 << 1)) 1,
    Test ((1 << 1) + 1) 1,

    Test ((1 << 2) - 1) 1,
    Test ((1 << 2)) 1,
    Test ((1 << 2) + 1) 1,

    Test ((1 << 3) - 1) 1,
    Test ((1 << 3)) 1,
    Test ((1 << 3) + 1) 1,

    Test ((1 << 4) - 1) 1,
    Test ((1 << 4)) 1,
    Test ((1 << 4) + 1) 1,

    Test ((1 << 5) - 1) 1,
    Test ((1 << 5)) 1,
    Test ((1 << 5) + 1) 1,

    Test ((1 << 6) - 1) 1,
    Test ((1 << 6)) 1,
    Test ((1 << 6) + 1) 1,

    Test ((1 << 7) - 1) 1,
    Test ((1 << 7)) 2,
    Test ((1 << 7) + 1) 2,

    Test ((1 << 8) - 1) 2,
    Test ((1 << 8)) 2,
    Test ((1 << 8) + 1) 2,

    Test ((1 << 9) - 1) 2,
    Test ((1 << 9)) 2,
    Test ((1 << 9) + 1) 2,

    Test ((1 << 10) - 1) 2,
    Test ((1 << 10)) 2,
    Test ((1 << 10) + 1) 2,

    Test ((1 << 11) - 1) 2,
    Test ((1 << 11)) 2,
    Test ((1 << 11) + 1) 2,

    Test ((1 << 12) - 1) 2,
    Test ((1 << 12)) 2,
    Test ((1 << 12) + 1) 2,

    Test ((1 << 13) - 1) 2,
    Test ((1 << 13)) 2,
    Test ((1 << 13) + 1) 2,

    Test ((1 << 14) - 1) 2,
    Test ((1 << 14)) 3,
    Test ((1 << 14) + 1) 3,

    Test ((1 << 15) - 1) 3,
    Test ((1 << 15)) 3,
    Test ((1 << 15) + 1) 3,

    Test ((1 << 16) - 1) 3,
    Test ((1 << 16)) 3,
    Test ((1 << 16) + 1) 3,

    Test ((1 << 17) - 1) 3,
    Test ((1 << 17)) 3,
    Test ((1 << 17) + 1) 3,

    Test ((1 << 18) - 1) 3,
    Test ((1 << 18)) 3,
    Test ((1 << 18) + 1) 3,

    Test ((1 << 19) - 1) 3,
    Test ((1 << 19)) 3,
    Test ((1 << 19) + 1) 3,

    Test ((1 << 20) - 1) 3,
    Test ((1 << 20)) 3,
    Test ((1 << 20) + 1) 3,

    Test ((1 << 21) - 1) 3,
    Test ((1 << 21)) 4,
    Test ((1 << 21) + 1) 4,

    Test ((1 << 22) - 1) 4,
    Test ((1 << 22)) 4,
    Test ((1 << 22) + 1) 4,

    Test ((1 << 23) - 1) 4,
    Test ((1 << 23)) 4,
    Test ((1 << 23) + 1) 4,

    Test ((1 << 24) - 1) 4,
    Test ((1 << 24)) 4,
    Test ((1 << 24) + 1) 4,

    Test ((1 << 25) - 1) 4,
    Test ((1 << 25)) 4,
    Test ((1 << 25) + 1) 4,

    Test ((1 << 26) - 1) 4,
    Test ((1 << 26)) 4,
    Test ((1 << 26) + 1) 4,

    Test ((1 << 27) - 1) 4,
    Test ((1 << 27)) 4,
    Test ((1 << 27) + 1) 4,

    Test ((1 << 28) - 1) 4,
    Test ((1 << 28)) 5,
    Test ((1 << 28) + 1) 5,

    Test ((1 << 29) - 1) 5,
    Test ((1 << 29)) 5,
    Test ((1 << 29) + 1) 5,

    Test ((1 << 30) - 1) 5,
    Test (1 << 30) 5,
    Test ((1 << 30) + 1) 5,

    Test ((1 << 31) - 1) 5,
    Test ((1 << 31)) 5,
    Test ((1 << 31) + 1) 5,

    Test ((1 << 32) - 1) 5,
    Test ((1 << 32)) 5,
    Test ((1 << 32) + 1) 5,

    Test ((1 << 33) - 1) 5,
    Test ((1 << 33)) 5,
    Test ((1 << 33) + 1) 5,

    Test ((1 << 34) - 1) 5,
    Test ((1 << 34)) 5,
    Test ((1 << 34) + 1) 5,

    Test ((1 << 35) - 1) 5,
    Test ((1 << 35)) 6,
    Test ((1 << 35) + 1) 6,

    Test ((1 << 36) - 1) 6,
    Test ((1 << 36)) 6,
    Test ((1 << 36) + 1) 6,

    Test ((1 << 37) - 1) 6,
    Test ((1 << 37)) 6,
    Test ((1 << 37) + 1) 6,

    Test ((1 << 38) - 1) 6,
    Test ((1 << 38)) 6,
    Test ((1 << 38) + 1) 6,

    Test ((1 << 39) - 1) 6,
    Test ((1 << 39)) 6,
    Test ((1 << 39) + 1) 6,

    Test ((1 << 40) - 1) 6,
    Test ((1 << 40)) 6,
    Test ((1 << 40) + 1) 6,

    Test ((1 << 41) - 1) 6,
    Test ((1 << 41)) 6,
    Test ((1 << 41) + 1) 6,

    Test ((1 << 42) - 1) 6,
    Test ((1 << 42)) 7,
    Test ((1 << 42) + 1) 7,

    Test ((1 << 43) - 1) 7,
    Test ((1 << 43)) 7,
    Test ((1 << 43) + 1) 7,

    Test ((1 << 44) - 1) 7,
    Test ((1 << 44)) 7,
    Test ((1 << 44) + 1) 7,

    Test ((1 << 45) - 1) 7,
    Test ((1 << 45)) 7,
    Test ((1 << 45) + 1) 7,

    Test ((1 << 46) - 1) 7,
    Test ((1 << 46)) 7,
    Test ((1 << 46) + 1) 7,

    Test ((1 << 47) - 1) 7,
    Test ((1 << 47)) 7,
    Test ((1 << 47) + 1) 7,

    Test ((1 << 48) - 1) 7,
    Test ((1 << 48)) 7,
    Test ((1 << 48) + 1) 7,

    Test ((1 << 49) - 1) 7,
    Test ((1 << 49)) 8,
    Test ((1 << 49) + 1) 8,

    Test ((1 << 50) - 1) 8,
    Test ((1 << 50)) 8,
    Test ((1 << 50) + 1) 8,

    Test ((1 << 51) - 1) 8,
    Test ((1 << 51)) 8,
    Test ((1 << 51) + 1) 8,

    Test ((1 << 52) - 1) 8,
    Test ((1 << 52)) 8,
    Test ((1 << 52) + 1) 8,

    Test ((1 << 53) - 1) 8,
    Test ((1 << 53)) 8,
    Test ((1 << 53) + 1) 8,

    Test ((1 << 54) - 1) 8,
    Test ((1 << 54)) 8,
    Test ((1 << 54) + 1) 8,

    Test ((1 << 55) - 1) 8,
    Test ((1 << 55)) 8,
    Test ((1 << 55) + 1) 8,

    Test ((1 << 56) - 1) 8,
    Test ((1 << 56)) 9,
    Test ((1 << 56) + 1) 9,

    Test ((1 << 57) - 1) 9,
    Test ((1 << 57)) 9,
    Test ((1 << 57) + 1) 9,

    Test ((1 << 58) - 1) 9,
    Test ((1 << 58)) 9,
    Test ((1 << 58) + 1) 9,

    Test ((1 << 59) - 1) 9,
    Test ((1 << 59)) 9,
    Test ((1 << 59) + 1) 9,

    Test ((1 << 60) - 1) 9,
    Test ((1 << 60)) 9,
    Test ((1 << 60) + 1) 9,

    Test ((1 << 61) - 1) 9,
    Test ((1 << 61)) 9,
    Test ((1 << 61) + 1) 9,

    Test ((1 << 62) - 1) 9,
    Test ((1 << 62)) 9,
    Test ((1 << 62) + 1) 9,

    Test ((1 << 63) - 1) 9,


  ]

negative_integer_tests ::= [
  Test -127 9,
  Test -128 9,
  Test -129 9,
]

main:
  benchmark

benchmark:
  tests := []
  tests.add_all positive_integer_tests
  tests.add_all negative_integer_tests
  tests.do: | t/Test |
    b := ByteArray 9
    s := encode b 0 t.i
    expect_equals t.size s
    expect_equals (byte_size b) s
    out := decode b 0
    expect_equals t.i out
