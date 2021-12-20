// Copyright (C) 2018 Toitware ApS. All rights reserved.

import math
import expect show *

main:
  test_smis_and_floats
  test_float_nan_and_infinite
  test_float_stringify
  test_special_values
  test_large_integers
  test_parse_integer
  test_parse_float
  test_round
  test_float_bin
  test_sign
  test_minus_zero
  test_compare_to
  test_shift
  test_minus
  test_random
  test_comparison
  test_to_int
  test_is_aligned
  test_is_power_of_two
  test_operators

expect_error name [code]:
  expect_equals
    name
    catch code

expect_int_invalid_radix [code]:
  expect_error "INVALID_RADIX" code

expect_int_parsing_error [code]:
  expect_error "INTEGER_PARSING_ERROR" code

expect_float_parsing_error [code]:
  expect_error "FLOAT_PARSING_ERROR" code

expect_number_out_of_range [code]:
  expect_error "OUT_OF_RANGE" code

expect_number_out_of_bounds [code]:
  expect_error "OUT_OF_BOUNDS" code

expect_number_invalid_argument [code]:
  expect_error "INVALID_ARGUMENT" code

expect_division_by_zero [code]:
  expect_error "DIVISION_BY_ZERO" code

test_round:
  expect_equals 0 (round_down 0 16)
  expect_equals 0 (round_down 0 15)
  expect_equals 0 (round_down 15 16)
  expect_equals 0 (round_down 14 15)
  expect_equals 16 (round_down 16 16)
  expect_equals 16 (round_down 17 16)
  expect_equals 16 (round_down 31 16)
  expect_equals 32 (round_down 32 16)
  expect_equals 32 (round_down 32 32)
  expect_equals 7 (round_down 7 7)
  expect_equals 7 (round_down 8 7)
  expect_equals 7 (round_down 13 7)
  expect_equals 14 (round_down 14 7)

  expect_equals 0 (round_up 0 16)
  expect_equals 0 (round_up 0 15)
  expect_equals 16 (round_up 15 16)
  expect_equals 15 (round_up 14 15)
  expect_equals 16 (round_up 16 16)
  expect_equals 32 (round_up 17 16)
  expect_equals 32 (round_up 31 16)
  expect_equals 32 (round_up 32 16)
  expect_equals 32 (round_up 32 32)
  expect_equals 7 (round_up 7 7)
  expect_equals 14 (round_up 8 7)
  expect_equals 14 (round_up 13 7)
  expect_equals 14 (round_up 14 7)

  expect_number_out_of_range: round_up 0 0
  expect_number_out_of_range: round_up 16 0
  expect_number_out_of_range: round_up -1 0
  expect_number_out_of_range: round_up -1 -1
  expect_number_out_of_range: round_up 16 -1
  expect_number_out_of_range: round_up -1 1

  expect_number_out_of_range: round_down 0 0
  expect_number_out_of_range: round_down 16 0
  expect_number_out_of_range: round_down -1 0
  expect_number_out_of_range: round_down -1 -1
  expect_number_out_of_range: round_down 16 -1
  expect_number_out_of_range: round_down -1 1

  expect_equals 2 2.0.round
  expect_equals 3 3.2.round
  expect_equals -3 (-3.4).round
  expect_equals -4 (-3.5).round
  expect_equals 3 (math.PI.round)

  big_float ::= math.pow 10 200
  expect_number_out_of_range: big_float.round
  expect_number_out_of_range: (-1.0 * big_float).round
  expect_number_out_of_range: float.INFINITY.round
  expect_number_out_of_range: float.NAN.round

// Parse helper that validates the input is parsable both as a string and a ByteArray.
int_parse_helper str/string from/int=0 to/int=str.size --radix/int=10 -> int:
  result := int.parse str[from..to] --radix=radix
  expect_equals
    result
    int.parse str.to_byte_array[from..to] --radix=radix
  return result

test_parse_integer:
  expect_equals 0 (int_parse_helper "0")
  expect_equals 0 (int_parse_helper "-0")
  expect_equals 1 (int_parse_helper "1")
  expect_equals -1 (int_parse_helper "-1")
  expect_equals 12 (int_parse_helper "12")
  expect_equals -12 (int_parse_helper "-12")
  expect_equals 12 (int_parse_helper "12")
  expect_equals -12 (int_parse_helper "-12")
  expect_equals 123 (int_parse_helper "123")
  expect_equals -123 (int_parse_helper "-123")
  expect_equals 123456789 (int_parse_helper "123456789")
  expect_equals 1234567890 (int_parse_helper "1234567890")
  expect_equals 12345678901 (int_parse_helper "12345678901")
  expect_equals 1073741823 (int_parse_helper "1073741823")
  expect_equals 1073741824 (int_parse_helper "1073741824")
  expect_equals -1073741823 (int_parse_helper "-1073741823")
  expect_equals -1073741823 - 1 (int_parse_helper "-1073741824")
  expect_equals -1073741825 (int_parse_helper "-1073741825")
  expect_equals 999999999999999999 (int_parse_helper "999999999999999999")
  expect_equals -999999999999999999 (int_parse_helper "-999999999999999999")
  expect_number_out_of_range: int_parse_helper "9999999999999999999"
  expect_number_out_of_range: int_parse_helper "-9999999999999999999"
  expect_number_out_of_range: int_parse_helper "9223372036854775808"
  expect_number_out_of_range: int_parse_helper "-9223372036854775809"
  expect_equals null (int.parse "9999999999999999999" --on_error=:
    expect_equals "OUT_OF_RANGE" it
    null)
  expect_equals -1 (int.parse "-9999999999999999999" --on_error=:
    expect_equals "OUT_OF_RANGE" it
    -1)

  expect_equals 1000 (int_parse_helper "1_000")
  expect_equals 1000000 (int_parse_helper "1_000_000")
  expect_equals -10 (int_parse_helper "-1_0")
  expect_equals 0 (int_parse_helper "-0_0")
  expect_int_parsing_error: int_parse_helper "_-10"
  expect_int_parsing_error: int_parse_helper "-_10"
  expect_int_parsing_error: int_parse_helper "-10_"
  expect_int_parsing_error: int_parse_helper "_10"
  expect_int_parsing_error: int_parse_helper "10_"
  expect_int_parsing_error: int_parse_helper "00_-10" 2 6
  expect_int_parsing_error: int_parse_helper "00-_10" 2 6
  expect_int_parsing_error: int_parse_helper "10_ 000" 0 3

  expect_equals 9223372036854775807 (int_parse_helper "9223372036854775807")
  expect_equals -9223372036854775807 - 1 (int_parse_helper "-9223372036854775808")
  expect_equals -9223372036854775807 - 1 (int_parse_helper " -9223372036854775808" 1 " -9223372036854775808".size)
  expect_int_parsing_error: int_parse_helper "foo"
  expect_int_parsing_error: int_parse_helper "--1"
  expect_int_parsing_error: int_parse_helper "1-1"
  expect_int_parsing_error: int_parse_helper "-"
  expect_int_parsing_error: int_parse_helper "-" --radix=16

  expect_equals 0
                int.parse "foo" --on_error=: 0

  expect_equals -2 (int_parse_helper " -2" 1 3)
  expect_equals 42 (int_parse_helper "level42" 5 7)

  expect_equals 499
                int.parse "level42"[4..5] --on_error=: 499

  expect_equals 0 (int_parse_helper --radix=16 "0")
  expect_equals 255 (int_parse_helper --radix=16 "fF")
  expect_equals 256 (int_parse_helper --radix=16 "100")
  expect_equals 15 (int_parse_helper --radix=16 "00f")
  expect_equals 0 (int_parse_helper --radix=16 "-0")
  expect_equals -255 (int_parse_helper --radix=16 "-fF")
  expect_equals -256 (int_parse_helper --radix=16 "-100")
  expect_equals -15 (int_parse_helper --radix=16 "-00f")

  expect_equals 0 (int_parse_helper "0" --radix=2)
  expect_equals 1 (int_parse_helper "1" --radix=2)
  expect_equals 3 (int_parse_helper "11" --radix=2)
  expect_equals 3 (int_parse_helper "011" --radix=2)
  expect_equals 1024 (int_parse_helper "10000000000" --radix=2)
  expect_equals -13 (int_parse_helper "-1101" --radix=2)
  expect_equals -16 (int_parse_helper "-10000" --radix=2)

  expect_equals 36 (int_parse_helper "10" --radix=36)

  expect_equals -2 (int_parse_helper " -2" 1 3)

  // Test that parse works on slices.
  expect_identical 125_00000_00000_00000 (int_parse_helper "x125000000000000000000000000000000000000000"[1..19])

  expect_equals 4096 (int_parse_helper "1_000" --radix=16)
  expect_equals 4095 (int_parse_helper "f_f_f" --radix=16)
  expect_equals 0 (int_parse_helper "0_0" --radix=16)
  expect_int_parsing_error: int.parse "_10" --radix=16
  expect_int_parsing_error: int.parse ("_10".to_byte_array) --radix=16
  expect_int_parsing_error: int.parse "10_" --radix=16
  expect_int_parsing_error: int.parse ("10_".to_byte_array) --radix=16
  expect_int_parsing_error: int.parse "0 _10"[2..5] --radix=16
  expect_int_parsing_error: int.parse ("0 _10".to_byte_array)[2..5] --radix=16
  expect_int_parsing_error: int.parse "10_   0"[0..3] --radix=16
  expect_int_parsing_error: int.parse ("10_   0".to_byte_array)[0..3] --radix=16
  expect_int_invalid_radix: int.parse ("10".to_byte_array) --radix=37
  expect_int_invalid_radix: int.parse ("10".to_byte_array) --radix=1

  expect_equals 0 (int_parse_helper "0" --radix=12)
  expect_equals 9 (int_parse_helper "9" --radix=12)
  expect_equals 10 (int_parse_helper "a" --radix=12)
  expect_equals 11 (int_parse_helper "b" --radix=12)
  expect_equals 21 (int_parse_helper "19" --radix=12)
  expect_equals 108 (int_parse_helper "90" --radix=12)

  expect_int_parsing_error: (int_parse_helper "a" --radix=2)
  expect_int_parsing_error: (int_parse_helper "2" --radix=2)
  expect_int_parsing_error: (int_parse_helper "5" --radix=4)
  expect_int_parsing_error: (int_parse_helper "c" --radix=12)
  expect_int_parsing_error: (int_parse_helper "g" --radix=16)
  expect_int_parsing_error: (int_parse_helper "h" --radix=17)

  expect_equals 9 (int.parse "1001" --radix=2)
  expect_equals int.MAX (int.parse       "111111111111111111111111111111111111111111111111111111111111111" --radix=2)
  expect_number_out_of_range: int.parse  "1000000000000000000000000000000000000000000000000000000000000000" --radix=2
  expect_equals int.MIN (int.parse      "-1000000000000000000000000000000000000000000000000000000000000000" --radix=2)
  expect_number_out_of_range: int.parse "-1000000000000000000000000000000000000000000000000000000000000001" --radix=2

  expect_equals 7 (int.parse "21" --radix=3)
  expect_equals int.MAX (int.parse       "2021110011022210012102010021220101220221" --radix=3)
  expect_number_out_of_range: int.parse  "2021110011022210012102010021220101220222" --radix=3
  expect_equals int.MIN (int.parse      "-2021110011022210012102010021220101220222" --radix=3)
  expect_number_out_of_range: int.parse "-2021110011022210012102010021220101221000" --radix=3

  expect_equals 11 (int.parse "23" --radix=4)
  expect_equals int.MAX (int.parse       "13333333333333333333333333333333" --radix=4)
  expect_number_out_of_range: int.parse  "20000000000000000000000000000000" --radix=4
  expect_equals int.MIN (int.parse      "-20000000000000000000000000000000" --radix=4)
  expect_number_out_of_range: int.parse "-20000000000000000000000000000001" --radix=4

  expect_equals 13 (int.parse "23" --radix=5)
  expect_equals int.MAX (int.parse       "1104332401304422434310311212" --radix=5)
  expect_number_out_of_range: int.parse  "1104332401304422434310311213" --radix=5
  expect_equals int.MIN (int.parse      "-1104332401304422434310311213" --radix=5)
  expect_number_out_of_range: int.parse "-1104332401304422434310311214" --radix=5

  expect_equals 54 (int.parse "66" --radix=8)
  expect_equals int.MAX (int.parse        "777777777777777777777" --radix=8)
  expect_number_out_of_range: int.parse  "1000000000000000000000" --radix=8
  expect_equals int.MIN (int.parse      "-1000000000000000000000" --radix=8)
  expect_number_out_of_range: int.parse "-1000000000000000000001" --radix=8

  expect_equals 102 (int.parse "66" --radix=16)
  expect_equals int.MAX (int.parse       "7fffffffffffffff" --radix=16)
  expect_number_out_of_range: int.parse  "8000000000000000" --radix=16
  expect_equals int.MIN (int.parse      "-8000000000000000" --radix=16)
  expect_number_out_of_range: int.parse "-8000000000000001" --radix=16

  expect_equals 24 (int.parse "17" --radix=17)
  expect_equals int.MAX (int.parse "33d3d8307b214008" --radix=17)
  expect_number_out_of_range: int.parse "33d3d8307b214009" --radix=17
  expect_equals int.MIN (int.parse "-33d3d8307b214009" --radix=17)
  expect_number_out_of_range: int.parse "-33d3d8307b21400a" --radix=17

  expect_equals 31839 (int.parse "v2v" --radix=32)
  expect_equals int.MAX (int.parse       "7vvvvvvvvvvvv" --radix=32)
  expect_number_out_of_range: int.parse  "8000000000000" --radix=32
  expect_equals int.MIN (int.parse      "-8000000000000" --radix=32)
  expect_number_out_of_range: int.parse "-8000000000001" --radix=32

  expect_equals 46655 (int.parse "zzz" --radix=36)
  expect_equals int.MAX (int.parse       "1y2p0ij32e8e7" --radix=36)
  expect_number_out_of_range: int.parse  "1y2p0ij32e8e8" --radix=36
  expect_equals int.MIN (int.parse      "-1y2p0ij32e8e8" --radix=36)
  expect_number_out_of_range: int.parse "-1y2p0ij32e8e9" --radix=36


// Parse helper that validates the input is parsable both as a string and a ByteArray.
float_parse_helper str/string from/int=0 to/int=str.size -> float:
  result := float.parse str[from..to]
  expect_equals
    result
    float.parse str.to_byte_array[from..to]
  return result

test_parse_float:
  expect_identical 1.0 (float_parse_helper "1.0")
  expect_identical 1.0 (float_parse_helper "+1.0")
  expect_identical 1.0 (float_parse_helper "+1")
  expect_identical 0.0 (float_parse_helper "0.0")
  expect_identical 0.0 (float_parse_helper "+0.0")
  expect_identical 0.0 (float_parse_helper "+0")
  expect_identical -0.0 (float_parse_helper "-0.0")
  expect_identical -0.0 (float_parse_helper "-0")

  expect_identical 0x123p15 (float_parse_helper "0x123p15")
  expect_identical -0x123p15 (float_parse_helper "-0x123p15")
  expect_identical 0x123p15 (float_parse_helper "+0x123p15")
  expect_identical 0x123p0 (float_parse_helper "0x123")
  expect_identical -0x123p0 (float_parse_helper "-0x123")
  expect_identical 0x123p0 (float_parse_helper "+0x123")

  // Test that parse works on slices.
  expect_identical 1.25 (float_parse_helper "x1.25000000000000000000000000000000000000000"[1..24])

  expect_identical 3.14 (float_parse_helper " 3.145" 1 5)
  expect_identical 3.14 (float_parse_helper "53.145" 1 5)

  expect_number_out_of_range: float.parse "1234"[2..2]
  expect_number_out_of_range: float.parse ("1234".to_byte_array)[2..2]
  expect_float_parsing_error: float.parse " 123"
  expect_float_parsing_error: float.parse (" 123".to_byte_array)
  expect_float_parsing_error: float.parse "3.14x"
  expect_float_parsing_error: float.parse ("3.14x".to_byte_array)


test_smis_and_floats:
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

  expect_division_by_zero: 123/0
  expect_division_by_zero: 123%0

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
  expect (top_level .5) == 2.5

  // Shift left smi overflow check.
  expect 698374 << 31 == 1499746745188352

expect_nan value:
  expect value.is_nan
  expect_equals "nan" value.stringify

expect_inf direction value:
  expect (not value.is_finite)
  expect_equals
    direction ? "inf" : "-inf"
    value.stringify

test_float_nan_and_infinite:
  expect_nan 123.12 % 0
  expect_nan -123.12 % 0
  expect_nan 123.12 % 0.0
  expect_nan -123.12 % 0.0
  expect_nan (-123.12).sqrt
  expect_inf true 123.12 / 0
  expect_inf true 123.12 / 0.0
  expect_inf false -123.12 / 0.0
  expect_inf true (-123.12 / 0.0).abs
  expect_nan float.NAN
  expect_inf true float.INFINITY
  expect (float.INFINITY > 0)
  expect_inf false -float.INFINITY
  expect (-float.INFINITY < 0)

test_special_values:
  expect_equals 1.7976931348623157e+308 float.MAX_FINITE
  expect_equals 5e-324 float.MIN_POSITIVE
  expect_equals float.INFINITY (float.MAX_FINITE * 2.0)
  expect_equals 0.0 (float.MIN_POSITIVE / 2.0)

top_level x:
  return x + 2

class Cls:
  method x:
    return x + 1

test_large_integers:
  // Test the behavior of large integers
  test_large_equality
  test_large_binary_operations
  test_large_bitwise_operations
  test_large_stringify
  test_based_stringify

test_large_equality:
  expect 0 == 0
  expect 0 == 0.0
  expect 0 == 0

test_large_binary_operations:
  expect 0 + 1 == 1
  expect 2 * 3 == 6.0
  expect 3 - 2 == 1
  expect (30000 * 212122 * 23 * 230) == (230 * 212122 * 23 * 30000)
  expect_division_by_zero: 123/0
  expect_division_by_zero: 123/0
  expect_division_by_zero: 123%0
  expect_division_by_zero: 123%0
  expect_equals 10 (100 / 10)
  expect_equals 10 (100 / 10)

test_large_bitwise_operations:
  expect_equals 0 (0 & 1)
  expect_equals 1 (0 | 1)
  expect_equals 2 (1 ^ 3)
  expect_equals 0 (0 & 1)
  expect_equals 1 (0 | 1)
  expect_equals 2 (1 ^ 3)
  ll := 1 << 60
  expect_equals (ll | ll) (ll & ll)
  expect_equals 0 (ll ^ ll)
  expect_equals 0x8000_0000_0000_0000 (-1 & 0x8000_0000_0000_0000)
  expect_equals 0xffff_ffff_f0f0_f0f0 (0xffff_ffff_f0f0_f0f0 | 0x0ff0_0000_0000_0000)
  expect_equals 0xf00f_ffff_f0f0_f0f0 (0xffff_ffff_f0f0_f0f0 ^ 0x0ff0_0000_0000_0000)

test_large_stringify:
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

test_based_stringify:
  37.repeat: | base |
    if base >= 2:
      expect_equals "0"
        0.stringify base
      expect_equals "-1"
        (-1).stringify base
      expect_equals "1"
        (1).stringify base
      expect_equals "10"
        base.stringify base
      expect_equals "-10"
        (-base).stringify base
      expect_equals "100"
        (base * base).stringify base
      expect_equals "-100"
        (-base * base).stringify base
  expect_equals "zz"
    (36 * 36 - 1).stringify 36
  expect_equals "-zz"
    (-36 * 36 + 1).stringify 36

  expect_equals "9223372036854775807"
    9223372036854775807.stringify
  expect_equals "111111111111111111111111111111111111111111111111111111111111111"
    9223372036854775807.stringify 2
  expect_equals "1y2p0ij32e8e7"
    9223372036854775807.stringify 36

  expect_equals "-9223372036854775808"
    (-9223372036854775808).stringify
  expect_equals "-1000000000000000000000000000000000000000000000000000000000000000"
    (-9223372036854775808).stringify 2
  expect_equals "-1y2p0ij32e8e8"
    (-9223372036854775808).stringify 36

test_float_stringify:
  // First check special float values.
  expect_equals "nan"  float.NAN.stringify
  expect_equals "inf"  float.INFINITY.stringify
  expect_equals "-inf" (-float.INFINITY).stringify
  // Then without precision
  expect_equals "123.0" (123.00).stringify
  // Testing Issue #323 has been fixed.
  //  "Printing of floating-point numbers is completely broken for larger numbers"
  expect_equals
    "1.7976931348623157081e+308"
    (1.7976931348623157e+308).stringify
  // Finally test with precision.
  expect_equals
    "123.00"
    (123.00).stringify 2
  expect_equals
    "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.0"
    (1.7976931348623157e+308).stringify 1
  // Ensure we can compare a >32 bit Smi with a large integer.
  expect_equals (0x1_0000_0000 == 0x7fff_ffff_ffff_ffff) false

test_float_bin:
  expect_equals 0 (0.0).bits
  expect_equals 0.0 (float.from_bits 0)

  expect_equals 4611686018427387904 (2.0).bits
  expect_equals 2.0 (float.from_bits 4611686018427387904)

  bits := (1.0).bits
  f := float.from_bits bits
  expect_equals 1.0 f

  expect_equals 0 (0.0).bits32
  expect_equals 0.0 (float.from_bits32 0)

  expect_equals 0x4000_0000 (2.0).bits32
  expect_equals 2.0 (float.from_bits32 0x4000_0000)

  expect_equals 0x7F80_0000 float.INFINITY.bits32
  expect_equals 0x7F80_0000 1e40.bits32
  expect_equals 0xFF80_0000 (-float.INFINITY).bits32
  expect_equals 0xFF80_0000 (-1e40).bits32

  f = float.from_bits 0x4001_2345_6789_0123
  expect_equals 2.1422222222028195482 f
  // The bits32 are just the truncated 64-bits.
  expect_equals 0x4009_1a2b f.bits32
  expect_equals (0x123456 >> 2) (0x91a2b >> 1)

  // The same as above, but now with a number that should round up.
  f = float.from_bits 0x4001_2345_7789_0123
  expect_equals 2.142222341412109099 f
  // The bits32 are just the rounded 64-bits.
  expect_equals 0x4009_1a2c f.bits32
  expect_equals (0x123458 >> 2) (0x91a2c >> 1)

  bits32 := (1.0).bits32
  f32 := float.from_bits32 bits32
  expect_equals 1.0 f32

  expect_throw "OUT_OF_RANGE": float.from_bits32 -1
  expect_throw "OUT_OF_RANGE": float.from_bits32 bits

test_sign:
  expect_equals 1 499.sign
  expect_equals -1 (-499).sign
  expect_equals 0 0.sign

  expect_equals 1 499.0.sign
  expect_equals -1 (-499.0).sign
  expect_equals 0 0.0.sign
  expect_equals -1 (-(0.0)).sign
  expect_equals -1 (-0.0).sign

  expect_equals 1 0x7FFF_FFFF_FFFF_FFFF.sign
  expect_equals -1 0x8000_0000_0000_0000.sign
  expect_equals -1 0x8000_0000_0000_FFFF.sign

  expect_equals 1 float.INFINITY.sign
  expect_equals -1 (-float.INFINITY).sign
  expect_equals 1 float.NAN.sign
  expect_equals 1 (-float.NAN).sign

test_minus_zero:
  expect_equals 0x8000_0000_0000_0000 (-0.0).bits

test_compare_to:
  expect_equals 1 (1.compare_to 0)
  expect_equals -1 (0.compare_to 1)
  expect_equals 0 (0.compare_to 0)
  expect_equals 1 (100.compare_to 99)
  expect_equals -1 (99.compare_to 100)
  expect_equals 0 (42.compare_to 42)

  min_int := 0x8000_0000_0000_0000
  expect_equals -1 (min_int.compare_to 0)
  expect_equals 1 (0.compare_to min_int)
  expect_equals 0 (min_int.compare_to min_int)

  expect_equals 1 (1.0.compare_to 0.0)
  expect_equals -1 (0.0.compare_to 1.0)
  expect_equals 0 (0.0.compare_to 0.0)
  expect_equals 1 (100.0.compare_to 99.0)
  expect_equals -1 (99.0.compare_to 100.0)
  expect_equals 0 (42.0.compare_to 42.0)

  expect_equals 1 (1.compare_to 0.0)
  expect_equals -1 (0.compare_to 1.0)
  expect_equals 0 (0.compare_to 0.0)
  expect_equals 1 (100.compare_to 99.0)
  expect_equals -1 (99.compare_to 100.0)
  expect_equals 0 (42.compare_to 42.0)

  expect_equals 1 (1.0.compare_to 0)
  expect_equals -1 (0.0.compare_to 1)
  expect_equals 0 (0.0.compare_to 0)
  expect_equals 1 (100.0.compare_to 99)
  expect_equals -1 (99.0.compare_to 100)
  expect_equals 0 (42.0.compare_to 42)

  expect_equals 1 ((0x1000_0000_0000_0000).compare_to 0)
  expect_equals -1 (0.compare_to 0x1000_0000_0000_0000)
  expect_equals 0 (0.compare_to 0)
  expect_equals 1 ((0x1000_0000_0000_0000).compare_to 99)
  expect_equals -1 (99.compare_to 0x1000_0000_0000_0000)
  expect_equals 0 ((0x1000_0000_0000_0000).compare_to 0x1000_0000_0000_0000)

  expect_equals -1 ((-1).compare_to 0)
  expect_equals 1 (0.compare_to -1)
  expect_equals 0 (0.compare_to 0)
  expect_equals -1 ((-100).compare_to -99)
  expect_equals 1 ((-99).compare_to -100)
  expect_equals 0 ((-42).compare_to -42)

  expect_equals 0 ((-0.0).compare_to -0.0)
  expect_equals 1 (0.0.compare_to -0.0)
  expect_equals -1 ((-0.0).compare_to 0.0)

  expect_equals 0 (float.INFINITY.compare_to float.INFINITY)
  expect_equals 0 ((-float.INFINITY).compare_to (-float.INFINITY))
  expect_equals 1 (float.INFINITY.compare_to 42.0)
  expect_equals 1 (float.INFINITY.compare_to 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals -1 ((-float.INFINITY).compare_to -42.0)
  expect_equals -1 ((-float.INFINITY).compare_to 0)
  expect_equals -1 ((-float.INFINITY).compare_to 0x8000_0000_0000_0000)

  expect_equals 0 (float.NAN.compare_to float.NAN)
  expect_equals 0 (float.NAN.compare_to (-float.NAN))
  expect_equals 0 ((-float.NAN).compare_to (-float.NAN))
  expect_equals 0 ((-float.NAN).compare_to float.NAN)
  expect_equals 1 (float.NAN.compare_to float.INFINITY)
  expect_equals 1 (float.NAN.compare_to 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 1 (float.NAN.compare_to 0x8FFF_FFFF_FFFF_FFFF)
  expect_equals 1 (float.NAN.compare_to 0.0)
  expect_equals 1 (float.NAN.compare_to -0.0)
  expect_equals 1 (float.NAN.compare_to 42)
  expect_equals -1 (float.INFINITY.compare_to float.NAN)
  expect_equals -1 ((0x7FFF_FFFF_FFFF_FFFF).compare_to float.NAN)
  expect_equals -1 ((0x8FFF_FFFF_FFFF_FFFF).compare_to float.NAN)
  expect_equals -1 (0.0.compare_to float.NAN)
  expect_equals -1 ((-0.0).compare_to float.NAN)
  expect_equals -1 (42.compare_to float.NAN)

  expect_equals 1 (1.compare_to 0 --if_equal=: throw "not used")
  expect_equals -1 (0.compare_to 1 --if_equal=: throw "not used")
  expect_equals 1 (0.compare_to 0 --if_equal=: 1)
  expect_equals -1 (0.compare_to 0 --if_equal=: -1)

  expect_equals 1 (1.0.compare_to 0.0 --if_equal=: throw "not used")
  expect_equals -1 (0.0.compare_to 1.0 --if_equal=: throw "not used")
  expect_equals -1 (0.0.compare_to 0.0 --if_equal=: -1)
  expect_equals 1 (42.0.compare_to 42.0 --if_equal=: 1)

  expect_equals 1 ((0x1000_0000_0000_0000).compare_to 0 --if_equal=: throw "not used")
  expect_equals -1 ((0x1000_0000_0000_0000).compare_to 0x1000_0000_0000_0000 --if_equal=: -1)
  expect_equals 1 ((0x1000_0000_0000_0000).compare_to 0x1000_0000_0000_0000 --if_equal=: 1)

  expect_equals -1 ((-0.0).compare_to 0.0 --if_equal=: throw "not used")
  expect_equals -1 ((-0.0).compare_to -0.0 --if_equal=: -1)
  expect_equals 1 ((-0.0).compare_to -0.0 --if_equal=: 1)

test_shift:
  expect_equals 2 (1 << 1)
  expect_equals 0x1000_0000_0000_0000 (1 << 60)
  expect_equals 0x1_0000_0000 (0x1000_0000 << 4)
  expect_equals 0x8000_0000_0000_0000 (1 << 63)
  expect (1 << 63) < 0
  expect_equals 0x8000_0000_0000_0000 (0x4000_0000_0000_0000 << 1)
  expect_equals 0 (1 << 64)
  expect_equals 0x1_0000_0000_0000 (0x1234_1234_0001_0000 << 32)
  expect_equals 0x8000_0000_0000_0000 (-1 << 63)

  expect_equals 1 (2 >> 1)
  expect_equals 1 (0x1000_0000_0000_0000 >> 60)
  expect_equals 0x1000_0000 (0x1_0000_0000 >> 4)
  expect_equals -1 (0x8000_0000_0000_0000 >> 63)
  expect_equals -1 (-1 >> 63)
  expect_equals -1 (-1 >> 100)
  expect_equals 0 (0x7FFF_0000_0000_0000 >> 63)
  expect_equals 0 (0x7FFF_0000_0000_0000 >> 100)
  expect_equals 0x1234 (0x1234_1111_2222_3333 >> 48)
  expect_equals 0xFFFF_FFFF_FFFF_8421 (0x8421_1111_2222_3333 >> 48)

  expect_equals 1 (2 >>> 1)
  expect_equals 1 (0x1000_0000_0000_0000 >>> 60)
  expect_equals 0x1000_0000 (0x1_0000_0000 >>> 4)
  expect_equals 1 (0x8000_0000_0000_0000 >>> 63)
  expect_equals 1 (-1 >>> 63)
  expect_equals 0 (-1 >>> 100)
  expect_equals 0 (0x7FFF_0000_0000_0000 >>> 63)
  expect_equals 0 (0x7FFF_0000_0000_0000 >>> 100)
  expect_equals 0x1234 (0x1234_1111_2222_3333 >>> 48)
  expect_equals 0x8421 (0x8421_1111_2222_3333 >>> 48)

  expect_equals 0 ((id 0xfff_ffff) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id 0xfff_ffff) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id 0xfff_ffff) << 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id 0xffff_ffff_ffff) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id 0xffff_ffff_ffff) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id 0xffff_ffff_ffff) << 0x7FFF_FFFF_FFFF_FFFF)

  expect_equals -1 ((id 0 - 0xfff_ffff) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id 0 - 0xfff_ffff) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id 0 - 0xfff_ffff) << 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals -1 ((id 0 - 0xffff_ffff_ffff) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id 0 - 0xffff_ffff_ffff) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id 0 - 0xffff_ffff_ffff) << 0x7FFF_FFFF_FFFF_FFFF)

  MIN_INT64 ::= -9223372036854775808
  MAX_INT64 ::= 9223372036854775807

  expect_equals 0 ((id MAX_INT64) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id MAX_INT64) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id MAX_INT64) << 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals -1 ((id MIN_INT64) >> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id MIN_INT64) >>> 0x7FFF_FFFF_FFFF_FFFF)
  expect_equals 0 ((id MIN_INT64) << 0x7FFF_FFFF_FFFF_FFFF)

id x: return x
test_minus:
  expect_equals -1 -(id 1)
  expect_equals 1 -(id -1)
  expect_equals 0 -(id 0)

  expect_equals -1099511627775 -(id 1099511627775)
  expect_equals 1099511627775 -(id -1099511627775)

  MIN_SMI32 ::= -1073741824
  MAX_SMI32 ::= 1073741823
  expect_equals MIN_SMI32 -(1 << 30)
  expect_equals MAX_SMI32 ((1 << 30) - 1)

  expect_equals 1073741824 -MIN_SMI32
  expect_equals -1073741823 -MAX_SMI32
  expect_equals -1073741824 -(-MIN_SMI32)
  expect_equals 1073741823 -(-MAX_SMI32)

  MIN_SMI64 ::= -4611686018427387904
  MAX_SMI64 ::= 4611686018427387903
  expect_equals MIN_SMI64 -(1 << 62)
  expect_equals MAX_SMI64 ((1 << 62) - 1)

  expect_equals 4611686018427387904 -MIN_SMI64
  expect_equals -4611686018427387903 -MAX_SMI64
  expect_equals -4611686018427387904 -(-MIN_SMI64)
  expect_equals 4611686018427387903 -(-MAX_SMI64)

  MIN_INT64 ::= -9223372036854775808
  MAX_INT64 ::= 9223372036854775807
  expect_equals 0x8000_0000_0000_0000 MIN_INT64
  expect_equals 0x7FFF_FFFF_FFFF_FFFF MAX_INT64

  expect_equals MIN_INT64 -MIN_INT64
  expect_equals -9223372036854775807 -MAX_INT64
  expect_equals MAX_INT64 -(-MAX_INT64)

  expect_equals -5.0 -(id 5.0)
  expect_equals -0.0 (-(id 0.0))
  expect_equals -1 (-(id 0.0)).sign

  expect_equals (-1.0 / 0.0) -float.INFINITY
  expect_equals 1 (-float.NAN).sign  // NaN isn't changed by '-'

  expect_equals -(0x8000_0000_0000_0000) 0x8000_0000_0000_0000 // This number cannot be negated.

test_random:
  set_random_seed "ostehaps"
  expect_equals 92 (random 256)
  expect_equals 141 (random 256)
  expect_equals 178 (random 256)

test_comparison:
  expect -1 < (id 1)
  expect 1 > (id -1)
  expect 0 == (id 0)

  one := id 1
  MIN_SMI32 ::= -1073741824
  MAX_SMI32 ::= 1073741823
  expect MIN_SMI32 == -(one << 30)
  expect MAX_SMI32 == ((one << 30) - 1)
  expect MIN_SMI32 < MIN_SMI32 + one
  expect MIN_SMI32 - one < MIN_SMI32

  expect 1073741824 == (id -MIN_SMI32)
  expect -1073741823 == (id -MAX_SMI32)
  expect -1073741824 == -(id -MIN_SMI32)
  expect 1073741823 == -(id -MAX_SMI32)

  expect 1073741824 < (id -MIN_SMI32) + one
  expect -1073741823 < (id -MAX_SMI32) + one
  expect -1073741824 < -(id -MIN_SMI32) + one
  expect 1073741823 < -(id -MAX_SMI32) + one

  expect 1073741824 > (id -MIN_SMI32) - one
  expect -1073741823 > (id -MAX_SMI32) - one
  expect -1073741824 > -(id -MIN_SMI32) - one
  expect 1073741823 > -(id -MAX_SMI32) - one

  MIN_SMI64 ::= -4611686018427387904
  MAX_SMI64 ::= 4611686018427387903
  expect MIN_SMI64 == -(one << 62)
  expect MAX_SMI64 == ((one << 62) - 1)

  expect 4611686018427387904 == (id -MIN_SMI64)
  expect -4611686018427387903 == (id -MAX_SMI64)
  expect -4611686018427387904 == -(id -MIN_SMI64)
  expect 4611686018427387903 == -(id -MAX_SMI64)

  expect 4611686018427387904 < (id -MIN_SMI64) + one
  expect -4611686018427387903 < (id -MAX_SMI64) + one
  expect -4611686018427387904 < -(id -MIN_SMI64) + one
  expect 4611686018427387903 < -(id -MAX_SMI64) + one

  expect 4611686018427387904 > (id -MIN_SMI64) - one
  expect -4611686018427387903 >  (id -MAX_SMI64) - one
  expect -4611686018427387904 > -(id -MIN_SMI64) - one
  expect 4611686018427387903 > -(id -MAX_SMI64) - one

  MIN_INT64 ::= -9223372036854775808
  MAX_INT64 ::= 9223372036854775807
  expect 0x8000_0000_0000_0000 == (id MIN_INT64)
  expect 0x7FFF_FFFF_FFFF_FFFF == (id MAX_INT64)

  expect MIN_INT64 == -(id MIN_INT64)
  expect -9223372036854775807 == -(id MAX_INT64)
  expect MAX_INT64 == -(id -MAX_INT64)

  expect MIN_INT64 < -(id MIN_INT64) + one
  expect -9223372036854775807 < -(id MAX_INT64) + one
  expect MAX_INT64 > -(id -MAX_INT64) - one

test_to_int:
  expect_equals 0 0.to_int
  expect_equals -123 -123.to_int
  expect_equals int.MAX int.MAX.to_int
  expect_equals int.MIN int.MIN.to_int

  expect_equals 42 42.0.to_int
  expect_equals -3 -3.0.to_int
  large_int ::= 9007199254740991
  expect_equals large_int large_int.to_float.to_int
  small_int ::= -9007199254740991
  expect_equals small_int small_int.to_float.to_int

  expect_number_out_of_range: float.MAX_FINITE.to_int
  expect_number_out_of_range: float.INFINITY.to_int
  expect_number_invalid_argument: float.NAN.to_int

test_is_power_of_two:
  expect 1.is_power_of_two
  expect 2.is_power_of_two
  expect 4.is_power_of_two
  expect 1024.is_power_of_two
  expect 4096.is_power_of_two
  expect 4611686018427387904.is_power_of_two

  expect_not 0.is_power_of_two
  expect_not (-1).is_power_of_two
  expect_not (-2).is_power_of_two
  expect_not (-4).is_power_of_two
  expect_not (-1024).is_power_of_two
  expect_not (-4096).is_power_of_two
  expect_not (-4611686018427387904).is_power_of_two

test_is_aligned:
  expect (4.is_aligned 4)
  expect (8.is_aligned 2)
  expect (16384.is_aligned 4096)
  expect (4611686018427387904.is_aligned 1024)

  expect (0.is_aligned 2)
  expect (0.is_aligned 4096)
  expect (0.is_aligned 4611686018427387904)

  expect_not (2.is_aligned 1024)
  expect_not (512.is_aligned 1024)
  expect_not (4096.is_aligned 4611686018427387904)

  expect_not (1.is_aligned 1024)
  expect_not (13.is_aligned 1024)

  expect_throw "INVALID ARGUMENT": 2.is_aligned 3
  expect_throw "INVALID ARGUMENT": 2.is_aligned 0
  expect_throw "INVALID ARGUMENT": 0.is_aligned 0

test_operators:
  // Test ==.
  expect 1 == 1  // => true
  expect_not 1 == 2  // => false
  expect_not 2 == 1  // => false

  expect 12.3 == 12.3  // => true
  expect_not 0.0 == 12.3   // => false
  expect_not 1.2 == 0.0    // => false

  expect 0.0 == -0.0   // => true
  expect 123 == 123.0     // => true
  expect 1.0 == 1         // => true

  expect_not float.NAN == float.NAN  // => false
  expect_not 1 == float.NAN          // => false
  expect_not float.NAN == 1.0        // => false

  expect float.INFINITY == float.INFINITY  // => true

  // Test <.
  expect_not 1 < 1  // => false
  expect 1 < 2  // => true
  expect_not 2 < 1  // => false

  expect_not 12.3 < 12.3  // => false
  expect 0.0 < 12.3  // => true
  expect_not 1.2 < 0.0   // => false
  expect_not 0.0 < -0.0  // => false
  expect_not -0.0 < 0.0  // => false

  expect_not 123 < 123.0     // => false
  expect_not 1.0 < 1         // => false

  expect_not float.NAN < float.NAN  // => false
  expect_not 1 < float.NAN          // => false
  expect_not float.NAN < 1.0        // => false

  expect float.MAX_FINITE < float.INFINITY  // => true
  expect_not float.NAN < float.INFINITY  // => false
  expect_not float.INFINITY < float.NAN  // => false

  // Test <=.
  expect 1 <= 1  // => true
  expect 1 <= 2  // => true
  expect_not 2 <= 1  // => false

  expect 12.3 <= 12.3  // => true
  expect 0.0 <= 12.3   // => true
  expect_not 1.2 <= 0.0    // => false
  expect 0.0 <= -0.0   // => true

  expect 12 <= 123.0    // => true
  expect 12.34 <= 123   // => true
  expect 32.0 <= 32     // => true
  expect 32 <= 32.0     // => true
  expect_not 1234 <= 123.0  // => false
  expect_not 1.2 <= 1       // => false

  expect_not float.NAN <= float.NAN  // => false
  expect_not 1 <= float.NAN          // => false
  expect_not float.NAN <= 1.0        // => false

  expect float.MAX_FINITE <= float.INFINITY  // => true
  expect_not float.NAN <= float.INFINITY  // => false
  expect_not float.INFINITY <= float.NAN  // => false

  // Test >.
  expect_not 1 > 1  // => false
  expect_not 1 > 2  // => false
  expect 2 > 1  // => true

  expect_not 12.3 > 12.3  // => false
  expect_not 0.0 > 12.3   // => false
  expect 1.2 > 0.0    // => true
  expect_not -0.0 > 0.0   // => false

  expect_not 12 > 123.0    // => false
  expect_not 12.34 > 123   // => false
  expect_not 32.0 > 32     // => false
  expect_not 32 > 32.0     // => false
  expect 1234 > 123.0  // => true
  expect 1.2 > 1       // => true

  expect_not float.NAN > float.NAN  // => false
  expect_not 1 > float.NAN          // => false
  expect_not float.NAN > 1.0        // => false

  expect_not float.MAX_FINITE > float.INFINITY  // => false
  expect_not float.NAN > float.INFINITY  // => false
  expect_not float.INFINITY > float.NAN  // => false

  // Test >=.
  expect 1 >= 1  // => true
  expect_not 1 >= 2  // => false
  expect 2 >= 1  // => true

  expect 12.3 >= 12.3  // => true
  expect_not 0.0 >= 12.3   // => false
  expect 1.2 >= 0.0    // => true
  expect -0.0 >= 0.0   // => true

  expect_not 12 >= 123.0    // => false
  expect_not 12.34 >= 123   // => false
  expect 32.0 >= 32     // => true
  expect 32 >= 32.0     // => true
  expect 1234 >= 123.0  // => true
  expect 1.2 >= 1       // => true

  expect_not float.NAN >= float.NAN  // => false
  expect_not 1 >= float.NAN          // => false
  expect_not float.NAN >= 1.0        // => false

  expect_not float.MAX_FINITE >= float.INFINITY  // => false
  expect_not float.NAN >= float.INFINITY  // => false
  expect_not float.INFINITY >= float.NAN  // => false

  // Test +.
  expect_equals 2 1 + 1           // => 2
  expect_equals 2.0 1.0 + 1.0       // => 2
  expect_equals 2.1000000000000000888 1 + 1.1         // => 2.1000000000000000888
  expect_equals -9223372036854775808 int.MAX + 1     // => -9223372036854775808
  expect_equals 9223372036854775807 int.MIN + (-1)  // => 9223372036854775807

  expect_nan 1 + float.NAN          // => float.NAN
  expect_nan float.NAN + 1          // => float.NAN
  expect_nan float.NAN + float.NAN  // => float.NAN

  expect_inf true float.INFINITY + 1  // => float.INFINITY
  expect_nan float.INFINITY + (-float.INFINITY)  // => float.INFINITY

  // Test -.
  expect_equals 44 46 - 2          // => 44
  expect_equals -2.0 1.0 - 3.0       // => 2.0
  expect_equals -0.10000000000000008882 1 - 1.1         // => -0.10000000000000008882
  expect_equals -9223372036854775808 int.MAX - (-1)  // => -9223372036854775808
  expect_equals 9223372036854775807 int.MIN - 1     // => 9223372036854775807

  expect_nan 1 - float.NAN          // => float.NAN
  expect_nan float.NAN - 1          // => float.NAN
  expect_nan float.NAN - float.NAN  // => float.NAN

  expect_inf true float.INFINITY - 1               // => float.INFINITY
  expect_nan float.INFINITY - float.INFINITY  // => float.nan

  // Test *.
  expect_equals 63 7 * 9         // => 63
  expect_equals -36 -12 * 3       // => -36
  expect_equals 6.0 2.0 * 3.0     // => 6.0
  expect_equals 2.2000000000000001776 2 * 1.1       // => 2.2000000000000001776
  expect_equals -9223372036854775807 -1 * int.MAX  // => -9223372036854775807
  expect_equals -9223372036854775808 -1 * int.MIN  // => -9223372036854775808

  expect_nan 1 * float.NAN          // => float.NAN
  expect_nan float.NAN * 1          // => float.NAN
  expect_nan float.NAN * float.NAN  // => float.NAN

  expect_inf true float.INFINITY * 1                // => float.INFINITY
  expect_inf true float.INFINITY * float.INFINITY   // => float.INFINITY
  expect_inf false -1 * float.INFINITY               // => -float.INFINITY
  expect_inf false float.INFINITY * -float.INFINITY  // => -float.INFINITY

  // Test /.
  expect_equals 23 46 / 2          // => 23
  expect_equals 0.5 2.0 / 4.0       // => 0.5
  expect_equals -0.33333333333333331483 -1 / 3.0 // => -0.33333333333333331483
  expect_throw "DIVISION_BY_ZERO": 2 / 0  // Error.
  expect_inf true 2 / 0.0   // => float.INFINITY
  expect_inf true 2.0 / 0   // => float.INFINITY
  expect_inf false 2.0 / -0.0   // => float.INFINITY

  expect_nan 1 / float.NAN          // => float.NAN
  expect_nan float.NAN / 1          // => float.NAN
  expect_nan float.NAN / float.NAN  // => float.NAN

  expect_inf true float.INFINITY / 2               // => float.INFINITY
  expect_nan float.INFINITY / float.INFINITY  // => float.NAN
  expect_identical 0.0 9001 / float.INFINITY            // => 0.0
  expect_identical -0.0 -1 / float.INFINITY              // => -0.0

  // Test %.
  expect_equals 2 5 % 3    // => 2
  expect_equals -2 -5 % 3   // => -2
  expect_equals 2 5 % -3   // => 2
  expect_equals -2 -5 % -3  // => -2
  expect_equals 0.0 6 % 1.5  // => 0.0
  expect_equals 2.2000000000000001776 5.2 % 3  // => 2.2000000000000001776

  expect_throw "DIVISION_BY_ZERO": 5 % 0    // => Error.
  expect_nan 2.0 % 0  // => float.NAN
  expect_nan 2 % 0.0  // => float.NAN

  expect_nan 1 % float.NAN          // => float.NAN
  expect_nan float.NAN % 1          // => float.NAN
  expect_nan float.NAN % float.NAN  // => float.NAN

  // Test to_float.

  expect_identical 2.0 2.to_float   // => 2.0
  expect_identical 2.1 2.1.to_float // => 2.1

  expect_identical 9223372036854775808.0 9223372036854775807.to_float  // => 9223372036854775808.0

  // Test compare_to.

  expect_equals 1
    2.compare_to 1  // => 1
  expect_equals 0
    1.compare_to 1  // => 0
  expect_equals -1
    1.compare_to 2  // => -1

  expect_equals -1
    (-0.0).compare_to 0.0 // => -1

  expect_equals -1
    2.compare_to float.NAN // => -1

  expect_equals 1
    float.INFINITY.compare_to 3               // => 1
  expect_equals 0
    float.INFINITY.compare_to float.INFINITY  // => 0
  expect_equals -1
    3.compare_to float.INFINITY               // => -1
