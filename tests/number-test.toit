// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import math
import expect show *

import .io-utils

main:
  test-smis-and-floats
  test-float-nan-and-infinite
  test-float-stringify
  test-special-values
  test-large-integers
  test-parse-number
  test-parse-integer
  test-parse-float
  test-round
  test-float-bin
  test-sign
  test-minus-zero
  test-compare-to
  test-shift
  test-minus
  test-random
  test-comparison
  test-to-int
  test-is-aligned
  test-is-power-of-two
  test-operators
  test-bit-fields
  test-abs-floor-ceil-truncate
  test-io-data
  test-unsigned-stringify

expect-error name [code]:
  expect-equals
    name
    catch code

expect-int-invalid-radix [code]:
  expect-error "INVALID_RADIX" code

expect-num-parsing-error [code]:
  expect-error "NUMBER_PARSING_ERROR" code

expect-int-parsing-error [code]:
  expect-error "INTEGER_PARSING_ERROR" code

expect-float-parsing-error [code]:
  expect-error "FLOAT_PARSING_ERROR" code

expect-number-out-of-range [code]:
  expect-error "OUT_OF_RANGE" code

expect-number-out-of-bounds [code]:
  expect-error "OUT_OF_BOUNDS" code

expect-number-invalid-argument [code]:
  expect-error "INVALID_ARGUMENT" code

expect-division-by-zero [code]:
  expect-error "DIVISION_BY_ZERO" code

test-round:
  expect-equals 0 (round-down 0 16)
  expect-equals 0 (round-down 0 15)
  expect-equals 0 (round-down 15 16)
  expect-equals 0 (round-down 14 15)
  expect-equals 16 (round-down 16 16)
  expect-equals 16 (round-down 17 16)
  expect-equals 16 (round-down 31 16)
  expect-equals 32 (round-down 32 16)
  expect-equals 32 (round-down 32 32)
  expect-equals 7 (round-down 7 7)
  expect-equals 7 (round-down 8 7)
  expect-equals 7 (round-down 13 7)
  expect-equals 14 (round-down 14 7)

  expect-equals 0 (round-up 0 16)
  expect-equals 0 (round-up 0 15)
  expect-equals 16 (round-up 15 16)
  expect-equals 15 (round-up 14 15)
  expect-equals 16 (round-up 16 16)
  expect-equals 32 (round-up 17 16)
  expect-equals 32 (round-up 31 16)
  expect-equals 32 (round-up 32 16)
  expect-equals 32 (round-up 32 32)
  expect-equals 7 (round-up 7 7)
  expect-equals 14 (round-up 8 7)
  expect-equals 14 (round-up 13 7)
  expect-equals 14 (round-up 14 7)

  expect-number-out-of-range: round-up 0 0
  expect-number-out-of-range: round-up 16 0
  expect-number-out-of-range: round-up -1 0
  expect-number-out-of-range: round-up -1 -1
  expect-number-out-of-range: round-up 16 -1
  expect-number-out-of-range: round-up -1 1

  expect-number-out-of-range: round-down 0 0
  expect-number-out-of-range: round-down 16 0
  expect-number-out-of-range: round-down -1 0
  expect-number-out-of-range: round-down -1 -1
  expect-number-out-of-range: round-down 16 -1
  expect-number-out-of-range: round-down -1 1

  expect-equals 2 2.0.round
  expect-equals 3 3.2.round
  expect-equals -3 (-3.4).round
  expect-equals -4 (-3.5).round
  expect-equals 3 (math.PI.round)

  big-float ::= math.pow 10 200
  expect-number-out-of-range: big-float.round
  expect-number-out-of-range: (-1.0 * big-float).round
  expect-number-out-of-range: float.INFINITY.round
  expect-number-out-of-range: float.NAN.round

test-parse-number:
  expect-identical 0 (num.parse "0")
  expect-identical 0 (num.parse "-0")
  expect-identical 0.0 (num.parse "0.0")

  expect-identical int.MAX (num.parse "0b111111111111111111111111111111111111111111111111111111111111111")
  // int.MAX + 1 can't be parsed as an integer, and is parsed as a float.
  expect-identical 9223372036854775808.0 (num.parse "9223372036854775808")

  expect-num-parsing-error: num.parse "foo"

// Parse helper that validates the input is parsable both as a string and a ByteArray.
int-parse-helper str/string from/int=0 to/int=str.size --radix/int=10 -> int:
  result := int.parse str[from..to] --radix=radix
  expect-equals
    result
    int.parse str.to-byte-array[from..to] --radix=radix
  return result

test-parse-integer:
  expect-equals 0 (int-parse-helper "0")
  expect-equals 0 (int-parse-helper "-0")
  expect-equals 1 (int-parse-helper "1")
  expect-equals -1 (int-parse-helper "-1")
  expect-equals 12 (int-parse-helper "12")
  expect-equals -12 (int-parse-helper "-12")
  expect-equals 12 (int-parse-helper "12")
  expect-equals -12 (int-parse-helper "-12")
  expect-equals 123 (int-parse-helper "123")
  expect-equals -123 (int-parse-helper "-123")
  expect-equals 123456789 (int-parse-helper "123456789")
  expect-equals 1234567890 (int-parse-helper "1234567890")
  expect-equals 12345678901 (int-parse-helper "12345678901")
  expect-equals 1073741823 (int-parse-helper "1073741823")
  expect-equals 1073741824 (int-parse-helper "1073741824")
  expect-equals -1073741823 (int-parse-helper "-1073741823")
  expect-equals -1073741823 - 1 (int-parse-helper "-1073741824")
  expect-equals -1073741825 (int-parse-helper "-1073741825")
  expect-equals 999999999999999999 (int-parse-helper "999999999999999999")
  expect-equals -999999999999999999 (int-parse-helper "-999999999999999999")
  expect-number-out-of-range: int-parse-helper "9999999999999999999"
  expect-number-out-of-range: int-parse-helper "-9999999999999999999"
  expect-number-out-of-range: int-parse-helper "9223372036854775808"
  expect-number-out-of-range: int-parse-helper "-9223372036854775809"
  expect-equals null (int.parse "9999999999999999999" --on-error=:
    expect-equals "OUT_OF_RANGE" it
    null)
  expect-equals -1 (int.parse "-9999999999999999999" --on-error=:
    expect-equals "OUT_OF_RANGE" it
    -1)

  expect-equals 1000 (int-parse-helper "1_000")
  expect-equals 1000000 (int-parse-helper "1_000_000")
  expect-equals -10 (int-parse-helper "-1_0")
  expect-equals 0 (int-parse-helper "-0_0")
  expect-int-parsing-error: int-parse-helper "_-10"
  expect-int-parsing-error: int-parse-helper "-_10"
  expect-int-parsing-error: int-parse-helper "-10_"
  expect-int-parsing-error: int-parse-helper "_10"
  expect-int-parsing-error: int-parse-helper "10_"
  expect-int-parsing-error: int-parse-helper "00_-10" 2 6
  expect-int-parsing-error: int-parse-helper "00-_10" 2 6
  expect-int-parsing-error: int-parse-helper "10_ 000" 0 3

  expect-equals 9223372036854775807 (int-parse-helper "9223372036854775807")
  expect-equals -9223372036854775807 - 1 (int-parse-helper "-9223372036854775808")
  expect-equals -9223372036854775807 - 1 (int-parse-helper " -9223372036854775808" 1 " -9223372036854775808".size)
  expect-int-parsing-error: int-parse-helper "foo"
  expect-int-parsing-error: int-parse-helper "--1"
  expect-int-parsing-error: int-parse-helper "1-1"
  expect-int-parsing-error: int-parse-helper "-"
  expect-int-parsing-error: int-parse-helper "-" --radix=16

  expect-equals 0
                int.parse "foo" --on-error=: 0
  expect-equals -1
                int.parse "" --on-error=: -1

  expect-equals -2 (int-parse-helper " -2" 1 3)
  expect-equals 42 (int-parse-helper "level42" 5 7)

  expect-equals 499
                int.parse "level42"[4..5] --on-error=: 499

  expect-equals 0 (int-parse-helper --radix=16 "0")
  expect-equals 255 (int-parse-helper --radix=16 "fF")
  expect-equals 256 (int-parse-helper --radix=16 "100")
  expect-equals 15 (int-parse-helper --radix=16 "00f")
  expect-equals 0 (int-parse-helper --radix=16 "-0")
  expect-equals -255 (int-parse-helper --radix=16 "-fF")
  expect-equals -256 (int-parse-helper --radix=16 "-100")
  expect-equals -15 (int-parse-helper --radix=16 "-00f")

  expect-equals 0 (int-parse-helper "0" --radix=2)
  expect-equals 1 (int-parse-helper "1" --radix=2)
  expect-equals 3 (int-parse-helper "11" --radix=2)
  expect-equals 3 (int-parse-helper "011" --radix=2)
  expect-equals 1024 (int-parse-helper "10000000000" --radix=2)
  expect-equals -13 (int-parse-helper "-1101" --radix=2)
  expect-equals -16 (int-parse-helper "-10000" --radix=2)

  expect-equals 36 (int-parse-helper "10" --radix=36)

  expect-equals -2 (int-parse-helper " -2" 1 3)

  // Test that parse works on slices.
  expect-identical 125_00000_00000_00000 (int-parse-helper "x125000000000000000000000000000000000000000"[1..19])

  expect-equals 4096 (int-parse-helper "1_000" --radix=16)
  expect-equals 4095 (int-parse-helper "f_f_f" --radix=16)
  expect-equals 0 (int-parse-helper "0_0" --radix=16)
  expect-int-parsing-error: int.parse "_10" --radix=16
  expect-int-parsing-error: int.parse ("_10".to-byte-array) --radix=16
  expect-int-parsing-error: int.parse "10_" --radix=16
  expect-int-parsing-error: int.parse ("10_".to-byte-array) --radix=16
  expect-int-parsing-error: int.parse "0 _10"[2..5] --radix=16
  expect-int-parsing-error: int.parse ("0 _10".to-byte-array)[2..5] --radix=16
  expect-int-parsing-error: int.parse "10_   0"[0..3] --radix=16
  expect-int-parsing-error: int.parse ("10_   0".to-byte-array)[0..3] --radix=16
  expect-int-invalid-radix: int.parse ("10".to-byte-array) --radix=37
  expect-int-invalid-radix: int.parse ("10".to-byte-array) --radix=1

  expect-equals 0 (int-parse-helper "0" --radix=12)
  expect-equals 9 (int-parse-helper "9" --radix=12)
  expect-equals 10 (int-parse-helper "a" --radix=12)
  expect-equals 11 (int-parse-helper "b" --radix=12)
  expect-equals 21 (int-parse-helper "19" --radix=12)
  expect-equals 108 (int-parse-helper "90" --radix=12)

  expect-int-parsing-error: (int-parse-helper "a" --radix=2)
  expect-int-parsing-error: (int-parse-helper "2" --radix=2)
  expect-int-parsing-error: (int-parse-helper "5" --radix=4)
  expect-int-parsing-error: (int-parse-helper "c" --radix=12)
  expect-int-parsing-error: (int-parse-helper "g" --radix=16)
  expect-int-parsing-error: (int-parse-helper "h" --radix=17)

  expect-int-parsing-error: (int-parse-helper "_")
  expect-int-parsing-error: (int-parse-helper "_123")
  expect-int-parsing-error: int.parse "1_123" 1  // @no-warn
  expect-int-parsing-error: int.parse "1012_" 1  // @no-warn
  expect-int-parsing-error: int.parse "1012_1" 1 5  // @no-warn
  expect-int-parsing-error: int.parse ""

  expect-number-out-of-bounds: (int.parse "123" -1 --on-error=: throw it)  // @no-warn
  expect-number-out-of-bounds: (int.parse "123" 0 4 --on-error=: throw it)  // @no-warn
  expect-int-parsing-error: (int.parse "123" 0 0 --on-error=: throw it)  // @no-warn

  expect-equals
      23
      int.parse "123" 1  // @no-warn
  expect-equals
      -23
      int.parse "1-23" 1  // @no-warn
  expect-equals
      23
      int.parse "1-23" 2  // @no-warn

  expect-equals 9 (int.parse "1001" --radix=2)
  expect-equals int.MAX (int.parse       "111111111111111111111111111111111111111111111111111111111111111" --radix=2)
  expect-number-out-of-range: int.parse  "1000000000000000000000000000000000000000000000000000000000000000" --radix=2
  expect-equals int.MIN (int.parse      "-1000000000000000000000000000000000000000000000000000000000000000" --radix=2)
  expect-number-out-of-range: int.parse "-1000000000000000000000000000000000000000000000000000000000000001" --radix=2
  expect-equals int.MAX (int.parse       "0b111111111111111111111111111111111111111111111111111111111111111")
  expect-number-out-of-range: int.parse  "0b1000000000000000000000000000000000000000000000000000000000000000"
  expect-equals int.MIN (int.parse      "-0b1000000000000000000000000000000000000000000000000000000000000000")
  expect-number-out-of-range: int.parse "-0b1000000000000000000000000000000000000000000000000000000000000001"

  expect-equals 7 (int.parse "21" --radix=3)
  expect-equals int.MAX (int.parse       "2021110011022210012102010021220101220221" --radix=3)
  expect-number-out-of-range: int.parse  "2021110011022210012102010021220101220222" --radix=3
  expect-equals int.MIN (int.parse      "-2021110011022210012102010021220101220222" --radix=3)
  expect-number-out-of-range: int.parse "-2021110011022210012102010021220101221000" --radix=3

  expect-equals 11 (int.parse "23" --radix=4)
  expect-equals int.MAX (int.parse       "13333333333333333333333333333333" --radix=4)
  expect-number-out-of-range: int.parse  "20000000000000000000000000000000" --radix=4
  expect-equals int.MIN (int.parse      "-20000000000000000000000000000000" --radix=4)
  expect-number-out-of-range: int.parse "-20000000000000000000000000000001" --radix=4

  expect-equals 13 (int.parse "23" --radix=5)
  expect-equals int.MAX (int.parse       "1104332401304422434310311212" --radix=5)
  expect-number-out-of-range: int.parse  "1104332401304422434310311213" --radix=5
  expect-equals int.MIN (int.parse      "-1104332401304422434310311213" --radix=5)
  expect-number-out-of-range: int.parse "-1104332401304422434310311214" --radix=5

  expect-equals 54 (int.parse "66" --radix=8)
  expect-equals int.MAX (int.parse        "777777777777777777777" --radix=8)
  expect-number-out-of-range: int.parse  "1000000000000000000000" --radix=8
  expect-equals int.MIN (int.parse      "-1000000000000000000000" --radix=8)
  expect-number-out-of-range: int.parse "-1000000000000000000001" --radix=8

  expect-equals 102 (int.parse "66" --radix=16)
  expect-equals int.MAX (int.parse       "7fffffffffffffff" --radix=16)
  expect-number-out-of-range: int.parse  "8000000000000000" --radix=16
  expect-equals int.MIN (int.parse      "-8000000000000000" --radix=16)
  expect-number-out-of-range: int.parse "-8000000000000001" --radix=16
  expect-equals int.MAX (int.parse       "0x7fffffffffffffff")
  expect-number-out-of-range: int.parse  "0x8000000000000000"
  expect-equals int.MIN (int.parse      "-0x8000000000000000")
  expect-number-out-of-range: int.parse "-0x8000000000000001"

  expect-equals 24 (int.parse "17" --radix=17)
  expect-equals int.MAX (int.parse "33d3d8307b214008" --radix=17)
  expect-number-out-of-range: int.parse "33d3d8307b214009" --radix=17
  expect-equals int.MIN (int.parse "-33d3d8307b214009" --radix=17)
  expect-number-out-of-range: int.parse "-33d3d8307b21400a" --radix=17

  expect-equals 31839 (int.parse "v2v" --radix=32)
  expect-equals int.MAX (int.parse       "7vvvvvvvvvvvv" --radix=32)
  expect-number-out-of-range: int.parse  "8000000000000" --radix=32
  expect-equals int.MIN (int.parse      "-8000000000000" --radix=32)
  expect-number-out-of-range: int.parse "-8000000000001" --radix=32

  expect-equals 46655 (int.parse "zzz" --radix=36)
  expect-equals int.MAX (int.parse       "1y2p0ij32e8e7" --radix=36)
  expect-number-out-of-range: int.parse  "1y2p0ij32e8e8" --radix=36
  expect-equals int.MIN (int.parse      "-1y2p0ij32e8e8" --radix=36)
  expect-number-out-of-range: int.parse "-1y2p0ij32e8e9" --radix=36

  expect-equals 16 (int.parse "10" --radix=16 --on-error=: throw it)
  expect-equals 15 (int.parse "10" --radix=15 --on-error=: throw it)

  expect-equals 16 (int.parse "foo10bar" --radix=16 3 5 --on-error=: throw it)  // @no-warn
  expect-equals 15 (int.parse "foo10bar" --radix=15 3 5 --on-error=: throw it)  // @no-warn

  expect-equals 16 (int.parse "0x10")
  expect-equals 16 (int.parse "0X10")
  expect-equals 16 (int.parse "foo0x10bar" 3 7)  // @no-warn
  expect-equals -16 (int.parse "foo-0x10bar" 3 8)  // @no-warn

  expect-equals 16 (int.parse "0x10".to-byte-array)
  expect-equals 16 (int.parse "foo0x10bar".to-byte-array 3 7)  // @no-warn

  expect-equals -1 (int.parse "0x" --on-error=: -1)
  expect-equals -1 (int.parse "-0x" --on-error=: -1)
  expect-equals -99 (int.parse "0x-1" --on-error=: -99)
  expect-equals -1 (int.parse "0a" --on-error=: -1)
  expect-equals -1 (int.parse "foo0xbar" 3 5 --on-error=: -1)  // @no-warn
  expect-equals -1 (int.parse "foo0x7bar" 3 5 --on-error=: -1)  // @no-warn
  expect-equals -1 (int.parse "foo0x-7bar" 3 6 --on-error=: -1)  // @no-warn

  expect-equals 16 (int.parse "0x10")
  expect-equals 16 (int.parse "0X10")
  expect-equals 16 (int.parse "foo0x10bar" 3 7)  // @no-warn
  expect-equals -16 (int.parse "foo-0x10bar" 3 8)  // @no-warn

  expect-equals 2 (int.parse "0b10".to-byte-array)
  expect-equals 2 (int.parse "foo0b10bar".to-byte-array 3 7)  // @no-warn

  expect-equals -1 (int.parse "0b" --on-error=: -1)
  expect-equals -1 (int.parse "-0b" --on-error=: -1)
  expect-equals -99 (int.parse "0b-1" --on-error=: -99)
  expect-equals -1 (int.parse "foo0bbar" 3 5 --on-error=: -1)  // @no-warn
  expect-equals -1 (int.parse "foo0b7bar" 3 5 --on-error=: -1)  // @no-warn
  expect-equals -1 (int.parse "foo0b-7bar" 3 6 --on-error=: -1)  // @no-warn

// Parse helper that validates the input is parsable both as a string and a ByteArray.
float-parse-helper str/string from/int=0 to/int=str.size -> float:
  result := float.parse str[from..to]
  expect-equals
    result
    float.parse str.to-byte-array[from..to]
  return result

test-parse-float:
  expect-identical 1.0 (float-parse-helper "1.0")
  expect-identical 1.0 (float-parse-helper "+1.0")
  expect-identical 1.0 (float-parse-helper "+1")
  expect-identical 0.0 (float-parse-helper "0.0")
  expect-identical 0.0 (float-parse-helper "+0.0")
  expect-identical 0.0 (float-parse-helper "+0")
  expect-identical -0.0 (float-parse-helper "-0.0")
  expect-identical -0.0 (float-parse-helper "-0")

  expect-identical 0x123p15 (float-parse-helper "0x123p15")
  expect-identical -0x123p15 (float-parse-helper "-0x123p15")
  expect-identical 0x123p15 (float-parse-helper "+0x123p15")
  expect-identical 0x123p0 (float-parse-helper "0x123")
  expect-identical -0x123p0 (float-parse-helper "-0x123")
  expect-identical 0x123p0 (float-parse-helper "+0x123")

  // Test that parse works on slices.
  expect-identical 1.25 (float-parse-helper "x1.25000000000000000000000000000000000000000"[1..24])

  expect-identical 3.14 (float-parse-helper " 3.145" 1 5)
  expect-identical 3.14 (float-parse-helper "53.145" 1 5)

  expect-number-out-of-range: float.parse "1234"[2..2]
  expect-number-out-of-range: float.parse ("1234".to-byte-array)[2..2]
  expect-float-parsing-error: float.parse " 123"
  expect-float-parsing-error: float.parse (" 123".to-byte-array)
  expect-float-parsing-error: float.parse "3.14x"
  expect-float-parsing-error: float.parse ("3.14x".to-byte-array)


test-smis-and-floats:
  // -- Integer operations.
  expect 1 + 1 == 2
  expect 2 * 3 == 6
  expect 4 % 3 == 1
  // Modulo has sign of dividend.
  expect -4 % 3 == -1
  expect 4 % -3 == 1
  expect 4 / 3 == 1
  expect -4 / 3 == -1
  expect 4 / -3 == -1

  // -- Float operations.
  expect 1.5 + 1.1 == 2.6
  expect 1.5 * 2.5 == 3.75
  expect 0.2 + 0.3 == 0.5
  expect -.2 + -.3 == -.5
  expect .2 + .3 == .5
  expect 5.5 % 2.5 == .5

  // Modulo has sign of dividend
  expect -5.5 % 2.5 == -0.5
  expect -5.5 % 2.5 == -.5
  expect 5.5 % -2.5 == .5
  expect -5.5 % -2.5 == -.5

  expect 5.5 / 2.5 == 2.2
  expect -5.5 / 2.5 == -2.2
  expect 5.5 / -2.5 == -2.2
  expect -5.5 / -2.5 == 2.2

  expect 0.0 == -0.0

  // -- Mixed operations
  expect 0 == 0.0
  expect 0 == -0.0
  expect 1 == 1.0

  expect 1 + 1.5 == 2.5
  expect 1.5 + 1 == 2.5
  expect 2.5 * 3 == 7.5

  expect 5.5 / 2 == 2.75
  expect -5.5 / 2 == -2.75
  expect 5.5 / -2 == -2.75
  expect -5.5 / -2 == 2.75

  expect 6 / 2.5 == 2.4
  expect -6 / 2.5 == -2.4
  expect 6 / -2.5 == -2.4
  expect -6 / -2.5 == 2.4
  expect 3 % 2.5 == .5

  expect-division-by-zero: 123/0
  expect-division-by-zero: 123%0

  // Modulo has sign of dividend
  expect -3 % 2.5 == -.5
  expect 3 % -2.5 == 0.5
  expect -3 % -2.5 == -0.5

  expect 3.5 % 2 == 1.5
  // Modulo has sign of dividend
  expect -3.5 % 2 == -1.5
  expect 3.5 % -2 == 1.5
  expect -3.5 % -2 == -1.5

  // Test sign on numbers
  expect 0.sign == 0
  expect (0.0).sign == 0
  expect 1.sign == 1
  expect (0.1).sign == 1
  expect (-1).sign == -1
  expect (-0.1).sign == -1
  expect (0.1).sign == 1
  expect (0.1/0.0).sign == 1
  expect (-0.1/0.0).sign == -1

  // Some parser challenges:
  cls := Cls
  expect (cls.method .5) == 1.5
  expect (top-level .5) == 2.5

  // Shift left smi overflow check.
  expect 698374 << 31 == 1499746745188352

expect-nan value:
  expect value.is-nan
  expect-equals "nan" value.stringify

expect-inf direction value:
  expect (not value.is-finite)
  expect-equals
    direction ? "inf" : "-inf"
    value.stringify

test-float-nan-and-infinite:
  expect-nan 123.12 % 0
  expect-nan -123.12 % 0
  expect-nan 123.12 % 0.0
  expect-nan -123.12 % 0.0
  expect-nan (-123.12).sqrt
  expect-inf true 123.12 / 0
  expect-inf true 123.12 / 0.0
  expect-inf false -123.12 / 0.0
  expect-inf true (-123.12 / 0.0).abs
  expect-nan float.NAN
  expect-inf true float.INFINITY
  expect (float.INFINITY > 0)
  expect-inf false -float.INFINITY
  expect (-float.INFINITY < 0)

test-special-values:
  expect-equals 1.7976931348623157e+308 float.MAX-FINITE
  expect-equals 5e-324 float.MIN-POSITIVE
  expect-equals float.INFINITY (float.MAX-FINITE * 2.0)
  expect-equals 0.0 (float.MIN-POSITIVE / 2.0)

top-level x:
  return x + 2

class Cls:
  method x:
    return x + 1

test-large-integers:
  // Test the behavior of large integers
  test-large-equality
  test-large-binary-operations
  test-large-bitwise-operations
  test-large-stringify
  test-based-stringify

test-large-equality:
  expect 0 == 0
  expect 0 == 0.0
  expect 0 == 0

test-large-binary-operations:
  expect 0 + 1 == 1
  expect 2 * 3 == 6.0
  expect 3 - 2 == 1
  expect (30000 * 212122 * 23 * 230) == (230 * 212122 * 23 * 30000)
  expect-division-by-zero: 123/0
  expect-division-by-zero: 123/0
  expect-division-by-zero: 123%0
  expect-division-by-zero: 123%0
  expect-equals 10 (100 / 10)
  expect-equals 10 (100 / 10)

test-large-bitwise-operations:
  expect-equals 0 (0 & 1)
  expect-equals 1 (0 | 1)
  expect-equals 2 (1 ^ 3)
  expect-equals 0 (0 & 1)
  expect-equals 1 (0 | 1)
  expect-equals 2 (1 ^ 3)
  ll := 1 << 60
  expect-equals (ll | ll) (ll & ll)
  expect-equals 0 (ll ^ ll)
  expect-equals 0x8000_0000_0000_0000 (-1 & 0x8000_0000_0000_0000)
  expect-equals 0xffff_ffff_f0f0_f0f0 (0xffff_ffff_f0f0_f0f0 | 0x0ff0_0000_0000_0000)
  expect-equals 0xf00f_ffff_f0f0_f0f0 (0xffff_ffff_f0f0_f0f0 ^ 0x0ff0_0000_0000_0000)

test-large-stringify:
  expect 0.stringify ==  "0"
  expect (0 + 1).stringify == "1"
  expect (2 * 3).stringify == "6"
  expect (1 + 0).stringify == "1"
  expect (3 * 2).stringify == "6"
  expect (3 - 2).stringify == "1"
  expect (2 - 3).stringify == "-1"
  expect (0 + 1.0).stringify == (1.0).stringify
  expect (2 * 3.0).stringify == (6.0).stringify
  expect (1.0 + 0).stringify == (1.0).stringify
  expect (3.0 * 2).stringify == (6.0).stringify
  expect (3 - 2.0).stringify == (1.0).stringify
  expect (2.0 - 3).stringify == (-1.0).stringify

test-based-stringify:
  37.repeat: | base |
    if base >= 2:
      expect-equals "0"
        0.stringify base
      expect-equals "-1"
        (-1).stringify base
      expect-equals "1"
        (1).stringify base
      expect-equals "10"
        base.stringify base
      expect-equals "-10"
        (-base).stringify base
      expect-equals "100"
        (base * base).stringify base
      expect-equals "-100"
        (-base * base).stringify base
  expect-equals "zz"
    (36 * 36 - 1).stringify 36
  expect-equals "-zz"
    (-36 * 36 + 1).stringify 36

  expect-equals "9223372036854775807"
    9223372036854775807.stringify
  expect-equals "111111111111111111111111111111111111111111111111111111111111111"
    9223372036854775807.stringify 2
  expect-equals "1y2p0ij32e8e7"
    9223372036854775807.stringify 36

  expect-equals "-9223372036854775808"
    (-9223372036854775808).stringify
  expect-equals "-1000000000000000000000000000000000000000000000000000000000000000"
    (-9223372036854775808).stringify 2
  expect-equals "-1y2p0ij32e8e8"
    (-9223372036854775808).stringify 36

test-float-stringify:
  // First check special float values.
  expect-equals "nan"  float.NAN.stringify
  expect-equals "inf"  float.INFINITY.stringify
  expect-equals "-inf" (-float.INFINITY).stringify
  // Then without precision
  expect-equals "123.0" (123.00).stringify
  // Testing Issue #323 has been fixed.
  //  "Printing of floating-point numbers is completely broken for larger numbers"
  expect-equals
    "1.7976931348623157081e+308"
    (1.7976931348623157e+308).stringify
  // Finally test with precision.
  expect-equals
    "123.00"
    (123.00).stringify 2
  expect-equals
    "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.0"
    (1.7976931348623157e+308).stringify 1
  // Ensure we can compare a >32 bit Smi with a large integer.
  expect-equals (0x1_0000_0000 == 0x7fff_ffff_ffff_ffff) false

test-unsigned-stringify:
  expect-equals "0" (0.stringify --uint64)
  expect-equals "1" (1.stringify --uint64)
  expect-equals "18446744073709551615" (-1.stringify --uint64)
  biggest-signed := 9223372036854775807
  next := biggest-signed + 1  // Wrap around.
  expect next < 0
  expect-equals "9223372036854775807" (9223372036854775807.stringify --uint64)
  expect-equals "9223372036854775808" (next.stringify --uint64)

test-float-bin:
  expect-equals 0 (0.0).bits
  expect-equals 0.0 (float.from-bits 0)

  expect-equals 4611686018427387904 (2.0).bits
  expect-equals 2.0 (float.from-bits 4611686018427387904)

  bits := (1.0).bits
  f := float.from-bits bits
  expect-equals 1.0 f

  expect-equals 0 (0.0).bits32
  expect-equals 0.0 (float.from-bits32 0)

  expect-equals 0x4000_0000 (2.0).bits32
  expect-equals 2.0 (float.from-bits32 0x4000_0000)

  expect-equals 0x7F80_0000 float.INFINITY.bits32
  expect-equals 0x7F80_0000 1e40.bits32
  expect-equals 0xFF80_0000 (-float.INFINITY).bits32
  expect-equals 0xFF80_0000 (-1e40).bits32

  f = float.from-bits 0x4001_2345_6789_0123
  expect-equals 2.1422222222028195482 f
  // The bits32 are just the truncated 64-bits.
  expect-equals 0x4009_1a2b f.bits32
  expect-equals (0x123456 >> 2) (0x91a2b >> 1)

  // The same as above, but now with a number that should round up.
  f = float.from-bits 0x4001_2345_7789_0123
  expect-equals 2.142222341412109099 f
  // The bits32 are just the rounded 64-bits.
  expect-equals 0x4009_1a2c f.bits32
  expect-equals (0x123458 >> 2) (0x91a2c >> 1)

  bits32 := (1.0).bits32
  f32 := float.from-bits32 bits32
  expect-equals 1.0 f32

  expect-throw "OUT_OF_RANGE": float.from-bits32 -1
  expect-throw "OUT_OF_RANGE": float.from-bits32 bits

test-sign:
  expect-equals 1 499.sign
  expect-equals -1 (-499).sign
  expect-equals 0 0.sign

  expect-equals 1 499.0.sign
  expect-equals -1 (-499.0).sign
  expect-equals 0 0.0.sign
  expect-equals -1 (-(0.0)).sign
  expect-equals -1 (-0.0).sign

  expect-equals 1 0x7FFF_FFFF_FFFF_FFFF.sign
  expect-equals -1 0x8000_0000_0000_0000.sign
  expect-equals -1 0x8000_0000_0000_FFFF.sign

  expect-equals 1 float.INFINITY.sign
  expect-equals -1 (-float.INFINITY).sign
  expect-equals 1 float.NAN.sign
  expect-equals 1 (-float.NAN).sign

test-minus-zero:
  expect-equals 0x8000_0000_0000_0000 (-0.0).bits

test-compare-to:
  test-simple-compare-to
  test-mixed-compare-to

test-simple-compare-to:
  expect-equals 1 (1.compare-to 0)
  expect-equals -1 (0.compare-to 1)
  expect-equals 0 (0.compare-to 0)
  expect-equals 1 (100.compare-to 99)
  expect-equals -1 (99.compare-to 100)
  expect-equals 0 (42.compare-to 42)

  min-int := 0x8000_0000_0000_0000
  expect-equals -1 (min-int.compare-to 0)
  expect-equals 1 (0.compare-to min-int)
  expect-equals 0 (min-int.compare-to min-int)

  expect-equals 1 (1.0.compare-to 0.0)
  expect-equals -1 (0.0.compare-to 1.0)
  expect-equals 0 (0.0.compare-to 0.0)
  expect-equals 1 (100.0.compare-to 99.0)
  expect-equals -1 (99.0.compare-to 100.0)
  expect-equals 0 (42.0.compare-to 42.0)

  expect-equals 1 (1.compare-to 0.0)
  expect-equals -1 (0.compare-to 1.0)
  expect-equals 0 (0.compare-to 0.0)
  expect-equals 1 (100.compare-to 99.0)
  expect-equals -1 (99.compare-to 100.0)
  expect-equals 0 (42.compare-to 42.0)

  expect-equals 1 (1.0.compare-to 0)
  expect-equals -1 (0.0.compare-to 1)
  expect-equals 0 (0.0.compare-to 0)
  expect-equals 1 (100.0.compare-to 99)
  expect-equals -1 (99.0.compare-to 100)
  expect-equals 0 (42.0.compare-to 42)

  expect-equals 1 ((0x1000_0000_0000_0000).compare-to 0)
  expect-equals -1 (0.compare-to 0x1000_0000_0000_0000)
  expect-equals 0 (0.compare-to 0)
  expect-equals 1 ((0x1000_0000_0000_0000).compare-to 99)
  expect-equals -1 (99.compare-to 0x1000_0000_0000_0000)
  expect-equals 0 ((0x1000_0000_0000_0000).compare-to 0x1000_0000_0000_0000)

  expect-equals -1 ((-1).compare-to 0)
  expect-equals 1 (0.compare-to -1)
  expect-equals 0 (0.compare-to 0)
  expect-equals -1 ((-100).compare-to -99)
  expect-equals 1 ((-99).compare-to -100)
  expect-equals 0 ((-42).compare-to -42)

  expect-equals 0 ((-0.0).compare-to -0.0)
  expect-equals 1 (0.0.compare-to -0.0)
  expect-equals -1 ((-0.0).compare-to 0.0)

  expect-equals 0 (float.INFINITY.compare-to float.INFINITY)
  expect-equals 0 ((-float.INFINITY).compare-to (-float.INFINITY))
  expect-equals 1 (float.INFINITY.compare-to 42.0)
  expect-equals 1 (float.INFINITY.compare-to 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals -1 ((-float.INFINITY).compare-to -42.0)
  expect-equals -1 ((-float.INFINITY).compare-to 0)
  expect-equals -1 ((-float.INFINITY).compare-to 0x8000_0000_0000_0000)

  expect-equals 0 (float.NAN.compare-to float.NAN)
  expect-equals 0 (float.NAN.compare-to (-float.NAN))
  expect-equals 0 ((-float.NAN).compare-to (-float.NAN))
  expect-equals 0 ((-float.NAN).compare-to float.NAN)
  expect-equals 1 (float.NAN.compare-to float.INFINITY)
  expect-equals 1 (float.NAN.compare-to 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 1 (float.NAN.compare-to 0x8FFF_FFFF_FFFF_FFFF)
  expect-equals 1 (float.NAN.compare-to 0.0)
  expect-equals 1 (float.NAN.compare-to -0.0)
  expect-equals 1 (float.NAN.compare-to 42)
  expect-equals -1 (float.INFINITY.compare-to float.NAN)
  expect-equals -1 ((0x7FFF_FFFF_FFFF_FFFF).compare-to float.NAN)
  expect-equals -1 ((0x8FFF_FFFF_FFFF_FFFF).compare-to float.NAN)
  expect-equals -1 (0.0.compare-to float.NAN)
  expect-equals -1 ((-0.0).compare-to float.NAN)
  expect-equals -1 (42.compare-to float.NAN)

  expect-equals 1 (1.compare-to 0 --if-equal=: throw "not used")
  expect-equals -1 (0.compare-to 1 --if-equal=: throw "not used")
  expect-equals 1 (0.compare-to 0 --if-equal=: 1)
  expect-equals -1 (0.compare-to 0 --if-equal=: -1)

  expect-equals 1 (1.0.compare-to 0.0 --if-equal=: throw "not used")
  expect-equals -1 (0.0.compare-to 1.0 --if-equal=: throw "not used")
  expect-equals -1 (0.0.compare-to 0.0 --if-equal=: -1)
  expect-equals 1 (42.0.compare-to 42.0 --if-equal=: 1)

  expect-equals 1 ((0x1000_0000_0000_0000).compare-to 0 --if-equal=: throw "not used")
  expect-equals -1 ((0x1000_0000_0000_0000).compare-to 0x1000_0000_0000_0000 --if-equal=: -1)
  expect-equals 1 ((0x1000_0000_0000_0000).compare-to 0x1000_0000_0000_0000 --if-equal=: 1)

  expect-equals -1 ((-0.0).compare-to 0.0 --if-equal=: throw "not used")
  expect-equals -1 ((-0.0).compare-to -0.0 --if-equal=: -1)
  expect-equals 1 ((-0.0).compare-to -0.0 --if-equal=: 1)

less --negate=false a/num b/num:
  expect a < b
  expect b > a
  expect a <= b
  expect b >= a
  expect-not a == b
  expect-not b == a
  expect-not a >= b
  expect-not b <= a
  expect-equals -1 (a.compare-to b)
  expect-equals  1 (b.compare-to a)
  if negate:
    expect-equals 1 ((-a).compare-to (-b))
    expect-equals -1 ((-b).compare-to (-a))

same --negate=false a/num b/num:
  expect a == b
  expect b == a
  expect a <= b
  expect b <= a
  expect a >= b
  expect b >= a
  expect-not a < b
  expect-not b < a
  expect-not a > b
  expect-not b > a
  expect-equals 0 (a.compare-to b)
  expect-equals 0 (b.compare-to a)
  if negate:
    expect-equals 0 ((-a).compare-to (-b))
    expect-equals 0 ((-b).compare-to (-a))

more --negate=false a/num b/num:
  expect a > b
  expect b < a
  expect a >= b
  expect b <= a
  expect-not a == b
  expect-not b == a
  expect-not a <= b
  expect-not b >= a
  expect-equals  1 (a.compare-to b)
  expect-equals -1 (b.compare-to a)
  if negate:
    expect-equals -1 ((-a).compare-to (-b))
    expect-equals  1 ((-b).compare-to (-a))

test-mixed-compare-to:
  more --negate 1 0.0
  less --negate 0 1.0
  same 0 0.0  // Negating floating zero changes it, but not negating int zero.
  more --negate 100 99.0
  less --negate 99 100.0
  same --negate 42 42.0

  // Here is a double that is on the absolute limit of the int64 range.
  // Adding and subtracting 1000 changes the double representation by one bit -
  // the last 13 bits are truncated by the limited size of the mantissa.
  LIMIT0 ::= 9223372036854775e3  // 0x7fff_ffff_ffff_F800.
  LIMIT1 ::= 9223372036854776e3  // 0x8000_0000_0000_0000.
  LIMIT2 ::= 9223372036854777e3  // 0x8000_0000_0000_0800.

  // The int runs out of range here, and the double has run out of precision a
  // while back.
  // A double that is slightly below int.MAX, then two that are slightly above.
  // There is no double that matches int.MAX exactly.
  less LIMIT0 int.MAX
  more LIMIT1 int.MAX
  more LIMIT2 int.MAX
  // Doubles that are slightly less, equal and more than int.MIN.
  more -LIMIT0 int.MIN
  same -LIMIT1 int.MIN
  less -LIMIT2 int.MIN

  // Exact matches and ints either side of that.
  more LIMIT0 9223372036854774783
  same LIMIT0 9223372036854774784  // Nearest double to ...5e3
  less LIMIT0 9223372036854774785

  less -LIMIT0 -9223372036854774783
  same -LIMIT0 -9223372036854774784  // Nearest double to ...5e3
  more -LIMIT0 -9223372036854774785
  less -LIMIT1 -9223372036854775807
  same -LIMIT1 -9223372036854775808  // Nearest double to ...6e3
  //           -9223372036854775809     This int is out of 64 bit signed range.

  // Test around where doubles start to run out of precision.
  // The first missing integral double is 2^53+1.
  TWO_53 ::= 0x20_0000_0000_0000
  TWO_53_F ::= TWO_53.to-float
  same --negate (TWO_53_F - 1) (TWO_53 - 1)
  less --negate (TWO_53_F - 1) (TWO_53    )
  less --negate (TWO_53_F - 1) (TWO_53 + 1)
  more --negate (TWO_53_F    ) (TWO_53 - 1)
  same --negate (TWO_53_F    ) (TWO_53    )
  less --negate (TWO_53_F    ) (TWO_53 + 1)
  // Adding 1 to this double doesn't change it.
  more --negate (TWO_53_F + 1) (TWO_53 - 1)
  same --negate (TWO_53_F + 1) (TWO_53    )
  less --negate (TWO_53_F + 1) (TWO_53 + 1)
  // Adding 2 does work though.
  more --negate (TWO_53_F + 2) (TWO_53 - 1)
  more --negate (TWO_53_F + 2) (TWO_53    )
  more --negate (TWO_53_F + 2) (TWO_53 + 1)
  same --negate (TWO_53_F + 2) (TWO_53 + 2)
  less --negate (TWO_53_F + 2) (TWO_53 + 3)

test-shift:
  expect-equals 2 (1 << 1)
  expect-equals 0x1000_0000_0000_0000 (1 << 60)
  expect-equals 0x1_0000_0000 (0x1000_0000 << 4)
  expect-equals 0x8000_0000_0000_0000 (1 << 63)
  expect (1 << 63) < 0
  expect-equals 0x8000_0000_0000_0000 (0x4000_0000_0000_0000 << 1)
  expect-equals 0 (1 << 64)
  expect-equals 0x1_0000_0000_0000 (0x1234_1234_0001_0000 << 32)
  expect-equals 0x8000_0000_0000_0000 (-1 << 63)

  expect-equals 1 (2 >> 1)
  expect-equals 1 (0x1000_0000_0000_0000 >> 60)
  expect-equals 0x1000_0000 (0x1_0000_0000 >> 4)
  expect-equals -1 (0x8000_0000_0000_0000 >> 63)
  expect-equals -1 (-1 >> 63)
  expect-equals -1 (-1 >> 100)
  expect-equals 0 (0x7FFF_0000_0000_0000 >> 63)
  expect-equals 0 (0x7FFF_0000_0000_0000 >> 100)
  expect-equals 0x1234 (0x1234_1111_2222_3333 >> 48)
  expect-equals 0xFFFF_FFFF_FFFF_8421 (0x8421_1111_2222_3333 >> 48)

  expect-equals 1 (2 >>> 1)
  expect-equals 1 (0x1000_0000_0000_0000 >>> 60)
  expect-equals 0x1000_0000 (0x1_0000_0000 >>> 4)
  expect-equals 1 (0x8000_0000_0000_0000 >>> 63)
  expect-equals 1 (-1 >>> 63)
  expect-equals 0 (-1 >>> 100)
  expect-equals 0 (0x7FFF_0000_0000_0000 >>> 63)
  expect-equals 0 (0x7FFF_0000_0000_0000 >>> 100)
  expect-equals 0x1234 (0x1234_1111_2222_3333 >>> 48)
  expect-equals 0x8421 (0x8421_1111_2222_3333 >>> 48)

  expect-equals 0 ((id 0xfff_ffff) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id 0xfff_ffff) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id 0xfff_ffff) << 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id 0xffff_ffff_ffff) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id 0xffff_ffff_ffff) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id 0xffff_ffff_ffff) << 0x7FFF_FFFF_FFFF_FFFF)

  expect-equals -1 ((id 0 - 0xfff_ffff) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id 0 - 0xfff_ffff) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id 0 - 0xfff_ffff) << 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals -1 ((id 0 - 0xffff_ffff_ffff) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id 0 - 0xffff_ffff_ffff) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id 0 - 0xffff_ffff_ffff) << 0x7FFF_FFFF_FFFF_FFFF)

  MIN-INT64 ::= -9223372036854775808
  MAX-INT64 ::= 9223372036854775807

  expect-equals 0 ((id MAX-INT64) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id MAX-INT64) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id MAX-INT64) << 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals -1 ((id MIN-INT64) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id MIN-INT64) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect-equals 0 ((id MIN-INT64) << 0x7FFF_FFFF_FFFF_FFFF)

id x: return x
test-minus:
  expect-equals -1 -(id 1)
  expect-equals 1 -(id -1)
  expect-equals 0 -(id 0)

  expect-equals -1099511627775 -(id 1099511627775)
  expect-equals 1099511627775 -(id -1099511627775)

  MIN-SMI32 ::= -1073741824
  MAX-SMI32 ::= 1073741823
  expect-equals MIN-SMI32 -(1 << 30)
  expect-equals MAX-SMI32 ((1 << 30) - 1)

  expect-equals 1073741824 -MIN-SMI32
  expect-equals -1073741823 -MAX-SMI32
  expect-equals -1073741824 -(-MIN-SMI32)
  expect-equals 1073741823 -(-MAX-SMI32)

  MIN-SMI64 ::= -4611686018427387904
  MAX-SMI64 ::= 4611686018427387903
  expect-equals MIN-SMI64 -(1 << 62)
  expect-equals MAX-SMI64 ((1 << 62) - 1)

  expect-equals 4611686018427387904 -MIN-SMI64
  expect-equals -4611686018427387903 -MAX-SMI64
  expect-equals -4611686018427387904 -(-MIN-SMI64)
  expect-equals 4611686018427387903 -(-MAX-SMI64)

  MIN-INT64 ::= -9223372036854775808
  MAX-INT64 ::= 9223372036854775807
  expect-equals 0x8000_0000_0000_0000 MIN-INT64
  expect-equals 0x7FFF_FFFF_FFFF_FFFF MAX-INT64

  expect-equals MIN-INT64 -MIN-INT64
  expect-equals -9223372036854775807 -MAX-INT64
  expect-equals MAX-INT64 -(-MAX-INT64)

  expect-equals -5.0 -(id 5.0)
  expect-equals -0.0 (-(id 0.0))
  expect-equals -1 (-(id 0.0)).sign

  expect-equals (-1.0 / 0.0) -float.INFINITY
  expect-equals 1 (-float.NAN).sign  // NaN isn't changed by '-'

  expect-equals -(0x8000_0000_0000_0000) 0x8000_0000_0000_0000 // This number cannot be negated.

test-random:
  set-random-seed "ostehaps"
  expect-equals 92 (random 256)
  expect-equals 141 (random 256)
  expect-equals 178 (random 256)

test-comparison:
  expect -1 < (id 1)
  expect 1 > (id -1)
  expect 0 == (id 0)

  one := id 1
  MIN-SMI32 ::= -1073741824
  MAX-SMI32 ::= 1073741823
  expect MIN-SMI32 == -(one << 30)
  expect MAX-SMI32 == ((one << 30) - 1)
  expect MIN-SMI32 < MIN-SMI32 + one
  expect MIN-SMI32 - one < MIN-SMI32

  expect 1073741824 == (id -MIN-SMI32)
  expect -1073741823 == (id -MAX-SMI32)
  expect -1073741824 == -(id -MIN-SMI32)
  expect 1073741823 == -(id -MAX-SMI32)

  expect 1073741824 < (id -MIN-SMI32) + one
  expect -1073741823 < (id -MAX-SMI32) + one
  expect -1073741824 < -(id -MIN-SMI32) + one
  expect 1073741823 < -(id -MAX-SMI32) + one

  expect 1073741824 > (id -MIN-SMI32) - one
  expect -1073741823 > (id -MAX-SMI32) - one
  expect -1073741824 > -(id -MIN-SMI32) - one
  expect 1073741823 > -(id -MAX-SMI32) - one

  MIN-SMI64 ::= -4611686018427387904
  MAX-SMI64 ::= 4611686018427387903
  expect MIN-SMI64 == -(one << 62)
  expect MAX-SMI64 == ((one << 62) - 1)

  expect 4611686018427387904 == (id -MIN-SMI64)
  expect -4611686018427387903 == (id -MAX-SMI64)
  expect -4611686018427387904 == -(id -MIN-SMI64)
  expect 4611686018427387903 == -(id -MAX-SMI64)

  expect 4611686018427387904 < (id -MIN-SMI64) + one
  expect -4611686018427387903 < (id -MAX-SMI64) + one
  expect -4611686018427387904 < -(id -MIN-SMI64) + one
  expect 4611686018427387903 < -(id -MAX-SMI64) + one

  expect 4611686018427387904 > (id -MIN-SMI64) - one
  expect -4611686018427387903 >  (id -MAX-SMI64) - one
  expect -4611686018427387904 > -(id -MIN-SMI64) - one
  expect 4611686018427387903 > -(id -MAX-SMI64) - one

  MIN-INT64 ::= -9223372036854775808
  MAX-INT64 ::= 9223372036854775807
  expect 0x8000_0000_0000_0000 == (id MIN-INT64)
  expect 0x7FFF_FFFF_FFFF_FFFF == (id MAX-INT64)

  expect MIN-INT64 == -(id MIN-INT64)
  expect -9223372036854775807 == -(id MAX-INT64)
  expect MAX-INT64 == -(id -MAX-INT64)

  expect MIN-INT64 < -(id MIN-INT64) + one
  expect -9223372036854775807 < -(id MAX-INT64) + one
  expect MAX-INT64 > -(id -MAX-INT64) - one

test-to-int:
  expect-equals 0 0.to-int
  expect-equals -123 -123.to-int
  expect-equals int.MAX int.MAX.to-int
  expect-equals int.MIN int.MIN.to-int

  expect-equals 42 42.0.to-int
  expect-equals -3 -3.0.to-int
  large-int ::= 9007199254740991
  expect-equals large-int large-int.to-float.to-int
  small-int ::= -9007199254740991
  expect-equals small-int small-int.to-float.to-int

  expect-number-out-of-range: float.MAX-FINITE.to-int
  expect-number-out-of-range: float.INFINITY.to-int
  expect-number-invalid-argument: float.NAN.to-int

  expect-equals int.MIN int.MIN.to-float.to-int
  // int.MAX is rounded up when converted to a float.  The resulting float is
  //   too large to convert back to an int.
  expect-equals int.MAX          9223372036854775807
  expect-equals int.MAX.to-float 9223372036854775808.0
  expect-number-out-of-range: int.MAX.to-float.to-int

test-is-power-of-two:
  expect 1.is-power-of-two
  expect 2.is-power-of-two
  expect 4.is-power-of-two
  expect 1024.is-power-of-two
  expect 4096.is-power-of-two
  expect 4611686018427387904.is-power-of-two

  expect-not 0.is-power-of-two
  expect-not (-1).is-power-of-two
  expect-not (-2).is-power-of-two
  expect-not (-4).is-power-of-two
  expect-not (-1024).is-power-of-two
  expect-not (-4096).is-power-of-two
  expect-not (-4611686018427387904).is-power-of-two

test-is-aligned:
  expect (4.is-aligned 4)
  expect (8.is-aligned 2)
  expect (16384.is-aligned 4096)
  expect (4611686018427387904.is-aligned 1024)

  expect (0.is-aligned 2)
  expect (0.is-aligned 4096)
  expect (0.is-aligned 4611686018427387904)

  expect-not (2.is-aligned 1024)
  expect-not (512.is-aligned 1024)
  expect-not (4096.is-aligned 4611686018427387904)

  expect-not (1.is-aligned 1024)
  expect-not (13.is-aligned 1024)

  expect-throw "INVALID ARGUMENT": 2.is-aligned 3
  expect-throw "INVALID ARGUMENT": 2.is-aligned 0
  expect-throw "INVALID ARGUMENT": 0.is-aligned 0

test-operators:
  // Test ==.
  expect 1 == 1  // => true
  expect-not 1 == 2  // => false
  expect-not 2 == 1  // => false

  expect 12.3 == 12.3  // => true
  expect-not 0.0 == 12.3   // => false
  expect-not 1.2 == 0.0    // => false

  expect 0.0 == -0.0   // => true
  expect 123 == 123.0     // => true
  expect 1.0 == 1         // => true

  expect-not float.NAN == float.NAN  // => false
  expect-not 1 == float.NAN          // => false
  expect-not float.NAN == 1.0        // => false

  expect float.INFINITY == float.INFINITY  // => true

  // Test <.
  expect-not 1 < 1  // => false
  expect 1 < 2  // => true
  expect-not 2 < 1  // => false

  expect-not 12.3 < 12.3  // => false
  expect 0.0 < 12.3  // => true
  expect-not 1.2 < 0.0   // => false
  expect-not 0.0 < -0.0  // => false
  expect-not -0.0 < 0.0  // => false

  expect-not 123 < 123.0     // => false
  expect-not 1.0 < 1         // => false

  expect-not float.NAN < float.NAN  // => false
  expect-not 1 < float.NAN          // => false
  expect-not float.NAN < 1.0        // => false

  expect float.MAX-FINITE < float.INFINITY  // => true
  expect-not float.NAN < float.INFINITY  // => false
  expect-not float.INFINITY < float.NAN  // => false

  // Test <=.
  expect 1 <= 1  // => true
  expect 1 <= 2  // => true
  expect-not 2 <= 1  // => false

  expect 12.3 <= 12.3  // => true
  expect 0.0 <= 12.3   // => true
  expect-not 1.2 <= 0.0    // => false
  expect 0.0 <= -0.0   // => true

  expect 12 <= 123.0    // => true
  expect 12.34 <= 123   // => true
  expect 32.0 <= 32     // => true
  expect 32 <= 32.0     // => true
  expect-not 1234 <= 123.0  // => false
  expect-not 1.2 <= 1       // => false

  expect-not float.NAN <= float.NAN  // => false
  expect-not 1 <= float.NAN          // => false
  expect-not float.NAN <= 1.0        // => false

  expect float.MAX-FINITE <= float.INFINITY  // => true
  expect-not float.NAN <= float.INFINITY  // => false
  expect-not float.INFINITY <= float.NAN  // => false

  // Test >.
  expect-not 1 > 1  // => false
  expect-not 1 > 2  // => false
  expect 2 > 1  // => true

  expect-not 12.3 > 12.3  // => false
  expect-not 0.0 > 12.3   // => false
  expect 1.2 > 0.0    // => true
  expect-not -0.0 > 0.0   // => false

  expect-not 12 > 123.0    // => false
  expect-not 12.34 > 123   // => false
  expect-not 32.0 > 32     // => false
  expect-not 32 > 32.0     // => false
  expect 1234 > 123.0  // => true
  expect 1.2 > 1       // => true

  expect-not float.NAN > float.NAN  // => false
  expect-not 1 > float.NAN          // => false
  expect-not float.NAN > 1.0        // => false

  expect-not float.MAX-FINITE > float.INFINITY  // => false
  expect-not float.NAN > float.INFINITY  // => false
  expect-not float.INFINITY > float.NAN  // => false

  // Test >=.
  expect 1 >= 1  // => true
  expect-not 1 >= 2  // => false
  expect 2 >= 1  // => true

  expect 12.3 >= 12.3  // => true
  expect-not 0.0 >= 12.3   // => false
  expect 1.2 >= 0.0    // => true
  expect -0.0 >= 0.0   // => true

  expect-not 12 >= 123.0    // => false
  expect-not 12.34 >= 123   // => false
  expect 32.0 >= 32     // => true
  expect 32 >= 32.0     // => true
  expect 1234 >= 123.0  // => true
  expect 1.2 >= 1       // => true

  expect-not float.NAN >= float.NAN  // => false
  expect-not 1 >= float.NAN          // => false
  expect-not float.NAN >= 1.0        // => false

  expect-not float.MAX-FINITE >= float.INFINITY  // => false
  expect-not float.NAN >= float.INFINITY  // => false
  expect-not float.INFINITY >= float.NAN  // => false

  // Test +.
  expect-equals 2 1 + 1           // => 2
  expect-equals 2.0 1.0 + 1.0       // => 2
  expect-equals 2.1000000000000000888 1 + 1.1         // => 2.1000000000000000888
  expect-equals -9223372036854775808 int.MAX + 1     // => -9223372036854775808
  expect-equals 9223372036854775807 int.MIN + (-1)  // => 9223372036854775807

  expect-nan 1 + float.NAN          // => float.NAN
  expect-nan float.NAN + 1          // => float.NAN
  expect-nan float.NAN + float.NAN  // => float.NAN

  expect-inf true float.INFINITY + 1  // => float.INFINITY
  expect-nan float.INFINITY + (-float.INFINITY)  // => float.INFINITY

  // Test -.
  expect-equals 44 46 - 2          // => 44
  expect-equals -2.0 1.0 - 3.0       // => 2.0
  expect-equals -0.10000000000000008882 1 - 1.1         // => -0.10000000000000008882
  expect-equals -9223372036854775808 int.MAX - (-1)  // => -9223372036854775808
  expect-equals 9223372036854775807 int.MIN - 1     // => 9223372036854775807

  expect-nan 1 - float.NAN          // => float.NAN
  expect-nan float.NAN - 1          // => float.NAN
  expect-nan float.NAN - float.NAN  // => float.NAN

  expect-inf true float.INFINITY - 1               // => float.INFINITY
  expect-nan float.INFINITY - float.INFINITY  // => float.nan

  // Test *.
  expect-equals 63 7 * 9         // => 63
  expect-equals -36 -12 * 3       // => -36
  expect-equals 6.0 2.0 * 3.0     // => 6.0
  expect-equals 2.2000000000000001776 2 * 1.1       // => 2.2000000000000001776
  expect-equals -9223372036854775807 -1 * int.MAX  // => -9223372036854775807
  expect-equals -9223372036854775808 -1 * int.MIN  // => -9223372036854775808

  expect-nan 1 * float.NAN          // => float.NAN
  expect-nan float.NAN * 1          // => float.NAN
  expect-nan float.NAN * float.NAN  // => float.NAN

  expect-inf true float.INFINITY * 1                // => float.INFINITY
  expect-inf true float.INFINITY * float.INFINITY   // => float.INFINITY
  expect-inf false -1 * float.INFINITY               // => -float.INFINITY
  expect-inf false float.INFINITY * -float.INFINITY  // => -float.INFINITY

  // Test /.
  expect-equals 23 46 / 2          // => 23
  expect-equals 0.5 2.0 / 4.0       // => 0.5
  expect-equals -0.33333333333333331483 -1 / 3.0 // => -0.33333333333333331483
  expect-throw "DIVISION_BY_ZERO": 2 / 0  // Error.
  expect-inf true 2 / 0.0   // => float.INFINITY
  expect-inf true 2.0 / 0   // => float.INFINITY
  expect-inf false 2.0 / -0.0   // => float.INFINITY

  expect-nan 1 / float.NAN          // => float.NAN
  expect-nan float.NAN / 1          // => float.NAN
  expect-nan float.NAN / float.NAN  // => float.NAN

  expect-inf true float.INFINITY / 2               // => float.INFINITY
  expect-nan float.INFINITY / float.INFINITY  // => float.NAN
  expect-identical 0.0 9001 / float.INFINITY            // => 0.0
  expect-identical -0.0 -1 / float.INFINITY              // => -0.0

  // Test %.
  expect-equals 2 5 % 3    // => 2
  expect-equals -2 -5 % 3   // => -2
  expect-equals 2 5 % -3   // => 2
  expect-equals -2 -5 % -3  // => -2
  expect-equals 0.0 6 % 1.5  // => 0.0
  expect-equals 2.2000000000000001776 5.2 % 3  // => 2.2000000000000001776

  expect-throw "DIVISION_BY_ZERO": 5 % 0    // => Error.
  expect-nan 2.0 % 0  // => float.NAN
  expect-nan 2 % 0.0  // => float.NAN

  expect-nan 1 % float.NAN          // => float.NAN
  expect-nan float.NAN % 1          // => float.NAN
  expect-nan float.NAN % float.NAN  // => float.NAN

  // Test to_float.

  expect-identical 2.0 2.to-float   // => 2.0
  expect-identical 2.1 2.1.to-float // => 2.1

  expect-identical 9223372036854775808.0 9223372036854775807.to-float  // => 9223372036854775808.0

  // Test compare_to.

  expect-equals 1
    2.compare-to 1  // => 1
  expect-equals 0
    1.compare-to 1  // => 0
  expect-equals -1
    1.compare-to 2  // => -1

  expect-equals -1
    (-0.0).compare-to 0.0 // => -1

  expect-equals -1
    2.compare-to float.NAN // => -1

  expect-equals 1
    float.INFINITY.compare-to 3               // => 1
  expect-equals 0
    float.INFINITY.compare-to float.INFINITY  // => 0
  expect-equals -1
    3.compare-to float.INFINITY               // => -1

test-bit-fields:
  expect-equals -1   (255.sign-extend --bits=8)
  expect-equals 1    (  1.sign-extend --bits=8)
  expect-equals -128 (128.sign-extend --bits=8)
  expect-equals 127  (127.sign-extend --bits=8)

  expect-equals -1   (  1.sign-extend --bits=1)
  expect-equals 0    (  0.sign-extend --bits=1)

  expect-equals int.MAX (int.MAX.sign-extend --bits=64)
  expect-equals int.MIN (int.MIN.sign-extend --bits=64)

test-abs-floor-ceil-truncate:
  expect-identical 0.0 0.0.abs
  expect-identical 0.0 0.0.floor
  expect-identical 0.0 0.0.ceil
  expect-identical 0.0 0.0.truncate

  expect-identical 0.0 -0.0.abs
  expect-identical -0.0 -0.0.floor
  expect-identical -0.0 -0.0.ceil
  expect-identical -0.0 -0.0.truncate

  expect-identical 1.0 1.0.abs
  expect-identical 1.0 1.0.floor
  expect-identical 1.0 1.0.ceil
  expect-identical 1.0 1.0.truncate

  expect-identical 1.5 1.5.abs
  expect-identical 1.0 1.5.floor
  expect-identical 2.0 1.5.ceil
  expect-identical 1.0 1.5.truncate

  expect-identical 1.0 -1.0.abs
  expect-identical -1.0 -1.0.floor
  expect-identical -1.0 -1.0.ceil
  expect-identical -1.0 -1.0.truncate

  expect-identical 1.5 -1.5.abs
  expect-identical -2.0 -1.5.floor
  expect-identical -1.0 -1.5.ceil
  expect-identical -1.0 -1.5.truncate

  expect-identical float.INFINITY float.INFINITY.abs
  expect-identical float.INFINITY float.INFINITY.floor
  expect-identical float.INFINITY float.INFINITY.ceil
  expect-identical float.INFINITY float.INFINITY.truncate

  expect-identical float.INFINITY (-float.INFINITY).abs
  expect-identical -float.INFINITY (-float.INFINITY).floor
  expect-identical -float.INFINITY (-float.INFINITY).ceil
  expect-identical -float.INFINITY (-float.INFINITY).truncate

  expect-identical float.NAN float.NAN.abs
  expect-identical float.NAN float.NAN.floor
  expect-identical float.NAN float.NAN.ceil
  expect-identical float.NAN float.NAN.truncate

test-io-data:
  expect-equals 3 (int.parse (FakeData "3"))
  expect-equals 3.1 (float.parse (FakeData "3.1"))
