// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import fixed-point show FixedPoint

main:
  x := FixedPoint "3.142"
  y := FixedPoint "2.717"

  // When parsing we default to the number of digits in the string.
  expect-equals "3.142" "$x"
  expect-equals "2.717" "$y"
  // Test addition
  expect-equals "5.859" "$(x + y)"
  // Use the max precision of the two inputs to plus.
  plus-0-1 := x + (FixedPoint.parse "0.1")
  expect-equals "3.242" "$plus-0-1"
  // Use the max precision of the two inputs to plus.
  plus-0-1 = x + (FixedPoint 0.1)
  expect-equals "3.242" "$plus-0-1"
  // Reverse order addition.
  plus-0-1 = (FixedPoint 0.1) + x
  expect-equals "3.242" "$plus-0-1"
  // Larger precision results in larger precision.
  plus-0-1 = x + (FixedPoint.parse --decimals=4 "0.1")
  expect-equals "3.2420" "$plus-0-1"
  // Multiplication with an integer.
  expect-equals "6.284" "$(x * 2)"
  // Division by an integer.
  expect-equals "1.571" "$(x / 2)"
  // Division rounds towards zero.
  expect-equals "1.047" "$(x / 3)"
  // Negative, division by an integer, also rounds to zero.
  expect-equals "-1.047" "$((-x) / 3)"
  // Modulus gives the remainder with a fractional part.
  expect-equals "1.142" "$(x % 2)"
  expect-equals "0.717" "$(y % 2)"
  // Modulus of a negative number gives a negative fractional part.
  expect-equals "-1.142" "$((-x) % 2)"
  expect-equals "-0.717" "$((-y) % 2)"
  // Division that is the counterpart of modulus
  expect-equals "-1" "$(((-x) / 2).to-int)"
  expect-equals "-1" "$(((-y) / 2).to-int)"
  // Verify that they combine.
  check-div-mod x 2
  check-div-mod -x 2
  check-div-mod y 2
  check-div-mod -y 2
  // to_int rounds towards zero.
  expect-equals 3 x.to-int
  // to_int rounds towards zero.
  expect-equals -3 (-x).to-int
  // Which is also what it does for floats.
  expect-equals -3 (-3.14).to-int
  expect-equals 3.142 x.to-float

  // We can set the precision when constructing from a floating point value.
  expect-equals "0.100" "$(FixedPoint --decimals=3 0.1)"
  // Precision defaults to 2 for use with currency.
  expect-equals "0.10" "$(FixedPoint 0.1)"

  // Round to nearest when limiting the precision.
  expect-equals "3.14" "$(FixedPoint --decimals=2 3.141592653)"
  expect-equals "3.142" "$(FixedPoint --decimals=3 3.141592653)"
  expect-equals "3.1416" "$(FixedPoint --decimals=4 3.141592653)"

  sum := 0.0
  10.repeat: sum += 0.1
  expect 1.0 != sum  // Fails because of floating point rounding.

  sum-fp := FixedPoint "0.0"
  10.repeat: sum-fp += FixedPoint "0.1"
  expect-equals "1.0" "$sum-fp"

  expect-equals "-123.12355" "$(FixedPoint "-123.12355")"
  expect-equals "-123" "$(FixedPoint "-123")"
  expect-equals "-123" "$(FixedPoint "-123.")"
  expect-equals "-123.4" "$(FixedPoint "-123.4")"
  expect-equals "-123.40" "$(FixedPoint --decimals=2 "-123.4")"
  expect-equals "-123.400" "$(FixedPoint --decimals=3 "-123.4")"

  expect-equals "256" "$(FixedPoint.parse --radix=16 "100")"
  expect-equals "256.00" "$(FixedPoint.parse --decimals=2 --radix=16 "100")"
  expect-equals "256.00" "$(FixedPoint.parse --decimals=2 --radix=16 "xx100xx" 2 5)"

  // Subtraction.
  expect-equals "0.425" "$(x - y)"

  expect x > y
  expect x >= y
  expect y < x
  expect y <= x
  expect y != x
  expect x != y
  expect x == x
  expect y == y

  expect-equals x 3.142
  expect-equals y 2.717

  expect-equals (x - x % 2) 2
  expect-equals (y - y % 2) 2

  expect-equals
    5.compare-to 7
    (FixedPoint "5.5").compare-to (FixedPoint "7.7")

  expect-equals
    7.compare-to 5
    (FixedPoint "7.7").compare-to (FixedPoint "5.5")

  expect-equals
    5.compare-to 5
    (FixedPoint "5.5").compare-to (FixedPoint "5.5")

  expect-equals
    (FixedPoint 5).compare-to 5
    5.compare-to 5

  expect-equals
    (FixedPoint 5).compare-to 7
    5.compare-to 7

  expect-equals
    (FixedPoint 5).compare-to 3
    5.compare-to 3

  expect-equals
    (FixedPoint 5).compare-to 0.0/0.0
    5.compare-to 0.0/0.0

  expect-equals
    (FixedPoint 5).compare-to 7.0
    5.compare-to 7.0

  expect-equals
    (FixedPoint 5).compare-to 3.0
    5.compare-to 3.0

  expect-equals
      1
      (FixedPoint 5).compare-to 5 --if-equal=: 1

  expect-equals
      0
      (FixedPoint 5).compare-to 5 --if-equal=: 0

  expect-equals
      1
      (FixedPoint 5).compare-to (FixedPoint 5) --if-equal=: 1

  expect-equals
      0
      (FixedPoint 5).compare-to (FixedPoint 5) --if-equal=: 0

  x = FixedPoint "3.14159"

  expect-equals "3.1" "$(x.with --decimals=1)"
  expect-equals "3.14" "$(x.with --decimals=2)"
  expect-equals "3.142" "$(x.with --decimals=3)"
  expect-equals "3.1416" "$(x.with --decimals=4)"
  expect-equals "3.14159" "$(x.with --decimals=5)"
  expect-equals "3.141590" "$(x.with --decimals=6)"
  expect-equals "3.1415900" "$(x.with --decimals=7)"

  x = -x

  expect-equals "-3.1" "$(x.with --decimals=1)"
  expect-equals "-3.14" "$(x.with --decimals=2)"
  expect-equals "-3.142" "$(x.with --decimals=3)"
  expect-equals "-3.1416" "$(x.with --decimals=4)"
  expect-equals "-3.14159" "$(x.with --decimals=5)"
  expect-equals "-3.141590" "$(x.with --decimals=6)"
  expect-equals "-3.1415900" "$(x.with --decimals=7)"

  // Test that we can call hash_code on FixedPoint objects.
  h := (FixedPoint 5.5).hash-code
  // Two FixedPoint objects that are equal should have the same hash code.
  expect-equals h ((FixedPoint 2.2) + (FixedPoint 3.3)).hash-code
  // Two FixedPoint Objects that are not equal should not generally have the
  // same hash code
  expect h != (FixedPoint 5.51).hash-code

check-div-mod value/FixedPoint divisor/int:
  dividend := (value / divisor).to-int
  remainder := value % divisor
  expect-equals
    value
    (FixedPoint dividend * divisor) + remainder
