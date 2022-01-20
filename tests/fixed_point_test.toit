// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import fixed_point show FixedPoint

main:
  x := FixedPoint "3.142"
  y := FixedPoint "2.717"

  // When parsing we default to the number of digits in the string.
  expect_equals "3.142" "$x"
  expect_equals "2.717" "$y"
  // Test addition
  expect_equals "5.859" "$(x + y)"
  // Use the max precision of the two inputs to plus.
  plus_0_1 := x + (FixedPoint.parse "0.1")
  expect_equals "3.242" "$plus_0_1"
  // Use the max precision of the two inputs to plus.
  plus_0_1 = x + (FixedPoint 0.1)
  expect_equals "3.242" "$plus_0_1"
  // Reverse order addition.
  plus_0_1 = (FixedPoint 0.1) + x
  expect_equals "3.242" "$plus_0_1"
  // Larger precision results in larger precision.
  plus_0_1 = x + (FixedPoint.parse --decimals=4 "0.1")
  expect_equals "3.2420" "$plus_0_1"
  // Multiplication with an integer.
  expect_equals "6.284" "$(x * 2)"
  // Division by an integer.
  expect_equals "1.571" "$(x / 2)"
  // Division rounds towards zero.
  expect_equals "1.047" "$(x / 3)"
  // Negative, division by an integer, also rounds to zero.
  expect_equals "-1.047" "$((-x) / 3)"
  // Modulus gives the remainder with a fractional part.
  expect_equals "1.142" "$(x % 2)"
  expect_equals "0.717" "$(y % 2)"
  // Modulus of a negative number gives a negative fractional part.
  expect_equals "-1.142" "$((-x) % 2)"
  expect_equals "-0.717" "$((-y) % 2)"
  // Division that is the counterpart of modulus
  expect_equals "-1" "$(((-x) / 2).to_int)"
  expect_equals "-1" "$(((-y) / 2).to_int)"
  // Verify that they combine.
  check_div_mod x 2
  check_div_mod -x 2
  check_div_mod y 2
  check_div_mod -y 2
  // to_int rounds towards zero.
  expect_equals 3 x.to_int
  // to_int rounds towards zero.
  expect_equals -3 (-x).to_int
  // Which is also what it does for floats.
  expect_equals -3 (-3.14).to_int
  expect_equals 3.142 x.to_float

  // We can set the precision when constructing from a floating point value.
  expect_equals "0.100" "$(FixedPoint --decimals=3 0.1)"
  // Precision defaults to 2 for use with currency.
  expect_equals "0.10" "$(FixedPoint 0.1)"

  // Round to nearest when limiting the precision.
  expect_equals "3.14" "$(FixedPoint --decimals=2 3.141592653)"
  expect_equals "3.142" "$(FixedPoint --decimals=3 3.141592653)"
  expect_equals "3.1416" "$(FixedPoint --decimals=4 3.141592653)"

  sum := 0.0
  10.repeat: sum += 0.1
  expect 1.0 != sum  // Fails because of floating point rounding.

  sum_fp := FixedPoint "0.0"
  10.repeat: sum_fp += FixedPoint "0.1"
  expect_equals "1.0" "$sum_fp"

  expect_equals "-123.12355" "$(FixedPoint "-123.12355")"
  expect_equals "-123" "$(FixedPoint "-123")"
  expect_equals "-123" "$(FixedPoint "-123.")"
  expect_equals "-123.4" "$(FixedPoint "-123.4")"
  expect_equals "-123.40" "$(FixedPoint --decimals=2 "-123.4")"
  expect_equals "-123.400" "$(FixedPoint --decimals=3 "-123.4")"

  expect_equals "256" "$(FixedPoint.parse --radix=16 "100")"
  expect_equals "256.00" "$(FixedPoint.parse --decimals=2 --radix=16 "100")"
  expect_equals "256.00" "$(FixedPoint.parse --decimals=2 --radix=16 "xx100xx" 2 5)"

  // Subtraction.
  expect_equals "0.425" "$(x - y)"

  expect x > y
  expect x >= y
  expect y < x
  expect y <= x
  expect y != x
  expect x != y
  expect x == x
  expect y == y

  expect_equals x 3.142
  expect_equals y 2.717

  expect_equals (x - x % 2) 2
  expect_equals (y - y % 2) 2

  expect_equals
    5.compare_to 7
    (FixedPoint "5.5").compare_to (FixedPoint "7.7")

  expect_equals
    7.compare_to 5
    (FixedPoint "7.7").compare_to (FixedPoint "5.5")

  expect_equals
    5.compare_to 5
    (FixedPoint "5.5").compare_to (FixedPoint "5.5")

  expect_equals
    (FixedPoint 5).compare_to 5
    5.compare_to 5

  expect_equals
    (FixedPoint 5).compare_to 7
    5.compare_to 7

  expect_equals
    (FixedPoint 5).compare_to 3
    5.compare_to 3

  expect_equals
    (FixedPoint 5).compare_to 0.0/0.0
    5.compare_to 0.0/0.0

  expect_equals
    (FixedPoint 5).compare_to 7.0
    5.compare_to 7.0

  expect_equals
    (FixedPoint 5).compare_to 3.0
    5.compare_to 3.0

  expect_equals
      1
      (FixedPoint 5).compare_to 5 --if_equal=: 1

  expect_equals
      0
      (FixedPoint 5).compare_to 5 --if_equal=: 0

  expect_equals
      1
      (FixedPoint 5).compare_to (FixedPoint 5) --if_equal=: 1

  expect_equals
      0
      (FixedPoint 5).compare_to (FixedPoint 5) --if_equal=: 0

  x = FixedPoint "3.14159"

  expect_equals "3.1" "$(x.with --decimals=1)"
  expect_equals "3.14" "$(x.with --decimals=2)"
  expect_equals "3.142" "$(x.with --decimals=3)"
  expect_equals "3.1416" "$(x.with --decimals=4)"
  expect_equals "3.14159" "$(x.with --decimals=5)"
  expect_equals "3.141590" "$(x.with --decimals=6)"
  expect_equals "3.1415900" "$(x.with --decimals=7)"

  x = -x

  expect_equals "-3.1" "$(x.with --decimals=1)"
  expect_equals "-3.14" "$(x.with --decimals=2)"
  expect_equals "-3.142" "$(x.with --decimals=3)"
  expect_equals "-3.1416" "$(x.with --decimals=4)"
  expect_equals "-3.14159" "$(x.with --decimals=5)"
  expect_equals "-3.141590" "$(x.with --decimals=6)"
  expect_equals "-3.1415900" "$(x.with --decimals=7)"

  // Test that we can call hash_code on FixedPoint objects.
  h := (FixedPoint 5.5).hash_code
  // Two FixedPoint objects that are equal should have the same hash code.
  expect_equals h ((FixedPoint 2.2) + (FixedPoint 3.3)).hash_code
  // Two FixedPoint Objects that are not equal should not generally have the
  // same hash code
  expect h != (FixedPoint 5.51).hash_code

check_div_mod value/FixedPoint divisor/int:
  dividend := (value / divisor).to_int
  remainder := value % divisor
  expect_equals
    value
    (FixedPoint dividend * divisor) + remainder
