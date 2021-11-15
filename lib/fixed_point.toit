// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
An object that behaves like a number.  It is implemented as
  a fixed-point decimal number with a given number of
  digits after the decimal point.  Unlike a float it does
  not have rounding issues, so adding 0.1 to a number 10
  times will add exactly 1 to it.  When comparing a FixedPoint
  with a float or int, place the FixedPoint object on the left
  side of the comparison operator.
*/
class FixedPoint implements Comparable:
  value/int
  decimals/int

  static MULTIPLIERS_ ::= [
    1,
    10,
    100,
    1000,
    10000,
    100000,
    1000000,
    10000000,
    100000000,
    1000000000,
    10000000000,
    100000000000,
    1000000000000,
    10000000000000,
    100000000000000,
    1000000000000000,
    10000000000000000,
    100000000000000000,
    1000000000000000000]

  constructor.private_ .decimals .value:

  /**
  Constructs a FixedPoint number from another number, or a string.
  If $value is a string, then the string is parsed and the
    precision is taken from the number of digits after the decimal
    point, string, ignoring $decimals.
  If $value is a floating point, then the result is rounded to the
    nearest fixed-point value, given the precision indicated in
    $decimals, which defaults to 2.
  If $value is an int, the $decimals defaults to 2.
  If $value is a FixedPoint, the precision of the result will be the max
    of $decimals or the precision of $value.
  */
  constructor value --decimals/int?=null:
    if value is string:
      return parse value --decimals=decimals
    decimals = decimals or 2
    if value is int:
      return FixedPoint.private_
        decimals
        value * MULTIPLIERS_[decimals]
    if value is float:
      return FixedPoint.private_
        decimals
        (value * MULTIPLIERS_[decimals] + value.sign * 0.5).to_int
    if value is FixedPoint:
      return (FixedPoint.private_ decimals 0) + value  // Get at least the right number of decimals.
    throw "INVALID_TYPE"

  common_ other [block] -> any:
    if other is int or other is float:
      other *= MULTIPLIERS_[decimals]
      return block.call value other decimals
    if other is FixedPoint:
      new_decimals := max decimals other.decimals
      value1 := value * MULTIPLIERS_[new_decimals - decimals]
      value2 := other.value * MULTIPLIERS_[new_decimals - other.decimals]
      return block.call value1 value2 new_decimals
    throw "INVALID_TYPE"

  operator == other -> bool:
    return common_ other: | a b | a == b

  operator < other -> bool:
    return common_ other: | a b | a < b

  operator <= other -> bool:
    return common_ other: | a b | a <= b

  operator > other -> bool:
    return common_ other: | a b | a > b

  operator >= other -> bool:
    return common_ other: | a b | a >= b

  /** See $(Comparable.compare_to other). */
  compare_to other -> int:
    return common_ other: | a b | a.compare_to b

  /** See $(Comparable.compare_to other [--if_equal]). */
  compare_to other [--if_equal] -> int:
    result := compare_to other
    if result == 0: return if_equal.call
    return result

  /**
  Addition operator.
  Returns a float if $other is a float.
  Returns a FixedPoint if $other is an int or a FixedPoint.
  */
  operator + other:
    if other is float:
      return value.to_float / MULTIPLIERS_[decimals] + other
    return common_ other: | a b decimals |
      FixedPoint.private_ decimals a + b

  /**
  Subtraction operator.
  Returns a float if $other is a float.
  Returns a FixedPoint if $other is an int or a FixedPoint.
  */
  operator - other:
    if other is float:
      return value.to_float / MULTIPLIERS_[decimals] - other
    return common_ other: | a b decimals |
      FixedPoint.private_ decimals a - b

  /**
  Multiplication operator.
  Returns a float if $other is a float.
  Returns a FixedPoint if $other is an int.
  Does not support multiplying two FixedPoint values with each other.
  */
  operator * other:
    if other is int:
      return FixedPoint.private_ decimals value * other
    if other is float:
      return (other * value) / MULTIPLIERS_[decimals]
    throw "INVALID_TYPE"

  /**
  Division operator.
  Returns a float if $other is a float.
  Returns a FixedPoint if $other is an int.  Rounds down, like the
    division operator on ints.
  Does not support dividing two FixedPoint values by each other.
  */
  operator / other:
    if other is int:
      return FixedPoint.private_ decimals value / other
    if other is float:
      return (value / other) / MULTIPLIERS_[decimals]
    throw "INVALID_TYPE"

  /**
  Returns a FixedPoint.  Eg. 3.14 % 2 == 1.14.
    This means it is not a counterpart of the / operator, but rather
    a counterpart of (x / y).to_int.
  */
  operator % other/int -> FixedPoint:
    if other is int:
      return FixedPoint.private_ decimals value % (other * MULTIPLIERS_[decimals])
    throw "INVALID_TYPE"

  operator - -> FixedPoint:
    if value == 0: return this
    return FixedPoint.private_ decimals -value

  /// Rounds down like the / operator.
  to_int -> int:
    return value / MULTIPLIERS_[decimals]

  to_float -> float:
    return value.to_float / MULTIPLIERS_[decimals]

  abs -> FixedPoint:
    return FixedPoint.private_ decimals (value.abs as int)

  sign -> int:
    return value.sign

  /**
  Parse string as a signed decimal integer.
  If $decimals is not given, then the actual number of digits
    after the decimal point is used for the precision.
  */
  static parse str/string from/int=0 to/int=str.size --radix=10 --decimals/int?=null -> FixedPoint:
    dot := str.index_of "." from to
    int_part := int.parse str[from..(dot == -1 ? to : dot)] --radix=radix --on_error=: throw it
    if dot == -1 or dot == to - 1:
      if not decimals: decimals = 0
      return FixedPoint.private_
        decimals
        int_part * MULTIPLIERS_[decimals]
    if radix != 10: throw "Can't parse fixed-point non-decimal numbers"
    decimals = decimals or to - 1 - dot
    if from != 0 or to != str.size:
      str = str.copy from to
    float_representation := float.parse str
    return FixedPoint --decimals=decimals float_representation

  stringify -> string:
    if value == 0: return "0"
    if decimals == 0:
      return "$value"
    sign := value < 0 ? "-" : ""
    multiplier := MULTIPLIERS_[decimals]
    return "$sign$(value.abs / multiplier).$(string.format "0$(decimals)d" value.abs % multiplier)"

  /// Returns a FixedPoint with a specific number of decimal digits.
  /// Mainly useful for printing.
  /// If the number of decimals is reduced, rounds to nearest.
  with --decimals/int:
    if decimals == this.decimals: return this
    if decimals > this.decimals: return (FixedPoint.private_ decimals 0) + this
    chopped_digits := this.decimals - decimals
    rounding := (MULTIPLIERS_[chopped_digits] >> 1) * value.sign
    return FixedPoint.private_
      decimals
      (value + rounding) / MULTIPLIERS_[chopped_digits]

  hash_code -> int:
    return value
