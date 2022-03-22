// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/** A number. */
abstract class num implements Comparable:
  equals_from_float_ other/float -> bool: return false
  equals_from_small_integer_ other/int -> bool: return false
  equals_from_large_integer_ other/int -> bool: return false

  /**
  Converts this number to an integer.

  # Errors
  This number must be inside the 64-bit integer range ([$int.MIN, $int.MAX]).
  This number must be a valid number and not a NaN ($float.NAN).

  # Examples
  ```
  42.to_int  // => 42

  (100.0).to_int   // => 100
  (-1.123).to_int  // => -1

  float.MAX_FINITE.to_int  // Error.
  float.INFINITY.to_int    // Error.
  float.NAN.to_int         // Error.
  ```
  */
  abstract to_int -> int

  /**
  The sign of this number.

  Returns -1 if this number is negative (including -0.0).
  Returns 0 if this number is 0.
  Returns 1 if this number is positive.
  Returns 1 if this number is a NaN ($float.NAN).

  # Examples
  ```
  (-500).sign // => -1
  (-1).sign   // => -1
  0.sign      // => 0
  1.sign      // => 1
  100.sign    // => 1

  (-2.0).sign  // => -1
  (-0.0).sign  // => -1
  0.0.sign     // => 0
  (3.123).sign // => 1

  float.INFINITY.sign    // => 1
  (-float.INFINITY).sign // => -1
  float.NAN.sign         // => 1
  (-float.NAN).sign      // => 1
  ```
  */
  abstract sign -> int

  /**
  Negates this number.

  The following numbers are not changed by negation:
  - -9223372036854775808 (0x8000_0000_0000_0000 or $int.MIN)
  - NaN ($float.NAN)

  # Examples
  ```
  -(2)                      // => -2
  -(-13)                    // => 13
  -(-9223372036854775808)  // => -9223372036854775808

  -(1.0)      // => -1.0
  -(-3.2)     // => 3.2
  -float.NAN  // => float.NAN
  ```
  */
  abstract operator -

  /**
  Whether this number is equal to the $other.

  Returns false if this number or the $other is a NaN ($float.NAN).

  # Examples
  ```
  1 == 1  // => true
  1 == 2  // => false
  2 == 1  // => false

  12.3 == 12.3  // => true
  0.0 == 12.3   // => false
  1.2 == 0.0    // => false
  0.0 == -0.0   // => true

  123 == 123.0     // => true
  1.0 == 1         // => true

  float.NAN == float.NAN  // => false
  1 == float.NAN          // => false
  float.NAN == 1.0        // => false

  float.INFINITY == float.INFINITY  // => true
  ```
  */
  abstract operator == other/num -> bool

  /**
  Whether this number is less than the $other.

  Returns false if this number or the $other is a NaN ($float.NAN)

  # Examples
  ```
  1 < 1  // => false
  1 < 2  // => true
  2 < 1  // => false

  12.3 < 12.3  // => false
  0.0 < 12.3   // => true
  1.2 < 0.0    // => false
  0.0 < -0.0   // => false
  -0.0 < 0.0   // => false

  12 < 123.0    // => true
  12.34 < 123   // => true
  1234 < 123.0  // => false
  1.2 < 1       // => false

  float.NAN < float.NAN  // => false
  1 < float.NAN          // => false
  float.NAN < 1.0        // => false

  float.MAX_FINITE < float.INFINITY  // => true
  float.NAN < float.INFINITY  // => false
  float.INFINITY < float.NAN  // => false
  ```
  */
  abstract operator <  other/num -> bool

  /**
  Whether this number is less than or equal to the $other.

  Returns false if this number or the $other is a NaN ($float.NAN).

  # Examples
  ```
  1 <= 1  // => true
  1 <= 2  // => true
  2 <= 1  // => false

  12.3 <= 12.3  // => true
  0.0 <= 12.3   // => true
  1.2 <= 0.0    // => false
  0.0 <= -0.0   // => true

  12 <= 123.0    // => true
  12.34 <= 123   // => true
  32.0 <= 32     // => true
  32 <= 32.0     // => true
  1234 <= 123.0  // => false
  1.2 <= 1       // => false

  float.NAN <= float.NAN  // => false
  1 <= float.NAN          // => false
  float.NAN <= 1.0        // => false

  float.MAX_FINITE <= float.INFINITY  // => true
  float.NAN <= float.INFINITY  // => false
  float.INFINITY <= float.NAN  // => false
  ```
  */
  abstract operator <= other/num -> bool

  /**
  Whether this number is greater than the $other.

  Returns false if this number or the $other is a NaN (float.NAN).

  # Examples
  ```
  1 > 1  // => false
  1 > 2  // => false
  2 > 1  // => true

  12.3 > 12.3  // => false
  0.0 > 12.3   // => false
  1.2 > 0.0    // => true
  -0.0 > 0.0   // => false

  12 > 123.0    // => false
  12.34 > 123   // => false
  32.0 > 32     // => false
  32 > 32.0     // => false
  1234 > 123.0  // => true
  1.2 > 1       // => true

  float.NAN > float.NAN  // => false
  1 > float.NAN          // => false
  float.NAN > 1.0        // => false

  float.MAX_FINITE > float.INFINITY  // => false
  float.NAN > float.INFINITY  // => false
  float.INFINITY > float.NAN  // => false
  ```
  */
  abstract operator >  other/num -> bool

  /**
  Whether this number is greater than or equal to the $other.

  Returns false if this number or the $other is a NaN ($float.NAN).

  # Examples
  ```
  1 >= 1  // => true
  1 >= 2  // => false
  2 >= 1  // => true

  12.3 >= 12.3  // => true
  0.0 >= 12.3   // => false
  1.2 >= 0.0    // => true
  -0.0 >= 0.0   // => true

  12 >= 123.0    // => false
  12.34 >= 123   // => false
  32.0 >= 32     // => true
  32 >= 32.0     // => true
  1234 >= 123.0  // => true
  1.2 >= 1       // => true

  float.NAN >= float.NAN  // => false
  1 >= float.NAN          // => false
  float.NAN >= 1.0        // => false

  float.MAX_FINITE >= float.INFINITY  // => false
  float.NAN >= float.INFINITY  // => false
  float.INFINITY >= float.NAN  // => false
  ```
  */
  abstract operator >= other/num -> bool

  /**
  Sums this number with the $other.

  Overflows if this number and the $other are integers and the result is
    outside the 64-bit integer range ([$int.MIN, $int.MAX]).

  Returns NaN ($float.NAN) if either this number of the $other is NaN.

  Returns infinity ($float.INFINITY) if either this number or the $other is
    infinity and the other is a scalar.

  Returns NaN when summing positive and negative infinity ($float.INFINITY).

  # Examples
  ```
  1 + 1           // => 2
  1.0 + 1.0       // => 2.0
  1 + 1.1         // => 2.1000000000000000888
  int.MAX + 1     // => -9223372036854775808
  int.MIN + (-1)  // => 9223372036854775807

  1 + float.NAN          // => float.NAN
  float.NAN + 1          // => float.NAN
  float.NAN + float.NAN  // => float.NAN

  float.INFINITY + 1                  // => float.INFINITY
  float.INFINITY + -float.INFINITY    // => float.NAN
  ```
  */
  abstract operator +  other/num

  /**
  Subtracts this number from the $other.

  Overflows if this number and the $other are integers and the result is
    outside the 64-bit integer range ([$int.MIN, $int.MAX]).

  Returns NaN ($float.NAN) if either this number of the $other is NaN.

  Returns infinity ($float.INFINITY) if either this number or the $other is
    infinity and the other is a scalar.

  # Examples
  ```
  46 - 2          // => 44
  1.0 - 3.0       // => -2.0
  1 - 1.1         // => -0.10000000000000008882
  int.MAX - (-1)  // => -9223372036854775808
  int.MIN - 1     // => 9223372036854775807

  1 - float.NAN          // => float.NAN
  float.NAN - 1          // => float.NAN
  float.NAN - float.NAN  // => float.NAN

  float.INFINITY - 1               // => float.INFINITY
  float.INFINITY - float.INFINITY  // => float.NAN
  ```
  */
  abstract operator -  other/num

  /**
  Multiplies this number with the $other.

  Overflows if this number and the $other are integers and the result is
    outside the 64-bit integer range ([$int.MIN, $int.MAX]).

  Returns NaN ($float.NAN) if either this number of the $other is NaN.

  Returns infinity ($float.INFINITY) if either this number or the $other is
    infinity and the other is not NaN.

  Returns NaN if both this numbers and the $other are infinity
    ($float.INFINITY).

  # Examples
  ```
  7 * 9         // => 63
  -12 * 3       // => -36
  2.0 * 3.0     // => 6.0
  2 * 1.1       // => 2.2000000000000001776
  -1 * int.MAX  // => -9223372036854775807
  -1 * int.MIN  // => -9223372036854775808

  1 * float.NAN          // => float.NAN
  float.NAN * 1          // => float.NAN
  float.NAN * float.NAN  // => float.NAN

  float.INFINITY * 1                // => float.INFINITY
  float.INFINITY * float.INFINITY   // => float.INFINITY
  -1 * float.INFINITY               // => -float.INFINITY
  float.INFINITY * -float.INFINITY  // => -float.INFINITY
  ```
  */
  abstract operator *  other/num

  /**
  Divides this number by the $other.

  Returns NaN ($float.NAN) if either this number of the $other is NaN.

  Returns infinity ($float.INFINITY) for division by zero if either this
    number or the $other is a float.

  Returns infinity ($float.INFINITY) if this number is infinity and the
    $other is a scalar.

  Returns 0.0 if either this number is a scalar and the $other is infinity
    ($float.INFINITY).

  Returns NaN ($float.NAN) if both this number and the $other are either
    infinity ($float.INFINITY).

  # Errors
  The $other must not be 0 when this number is an $int.

  # Examples
  ```
  46 / 2    // => 23
  2.0 / 4.0 // => 0.5
  -1 / 3.0  // => -0.33333333333333331483

  2 / 0     // Error.
  2.0 / 0   // => float.INFINITY
  2 / 0.0   // => float.INFINITY
  2 / -0.0   // => -float.INFINITY

  1 / float.NAN          // => float.NAN
  float.NAN / 1          // => float.NAN
  float.NAN / float.NAN  // => float.NAN

  float.INFINITY / 2               // => float.INFINITY
  float.INFINITY / float.INFINITY  // => float.NAN
  ```
  */
  abstract operator /  other/num

  /**
  Takes this number modulo the $other.

  Uses the truncated division for the modulo computation. The sign of the
    result is thus always the same as the one of the divisor (the first
    operand).

  Returns NaN ($float.NAN) if this number or the $other is a float and the
    $other is equal to 0.0.

  Returns NaN ($float.NAN) if either this number or the $other is a NaN.

  # Errors
  The $other must not be 0 when this number is an $int.

  # Examples
  ```
  5 % 3    // => 2
  -5 % 3   // => -2
  5 % -3   // => 2
  -5 % -3  // => -2
  6 % 1.5  // => 0.0
  5.2 % 3  // => 2.2000000000000001776

  5 % 0    // => Error.
  2.0 % 0  // => float.NAN
  2 % 0.0  // => float.NAN

  1 % float.NAN          // => float.NAN
  float.NAN % 1          // => float.NAN
  float.NAN % float.NAN  // => float.NAN
  ```
  */
  abstract operator %  other/num

  /**
  Compares this number to the $other.

  Uses the truncated division for the modulo computation. The sign
    of the result is thus always the same as the one of the
    divisor (the first operand).

  Returns 1 if this number is greater than the $other.
  Returns 0 if this number is equal to the $other.
  Returns -1 if this number is less than the $other.

  Returns -1 if the $other is NaN ($float.NAN).
  Returns 0 if both this number and the $other are NaN ($float.NAN).
  Return 1 if this number is NaN and the $other is not NaN.


  Contrary to `<` this comparison handles `0.0` and `-0.0`, such that
    `0.0.compare_to -0.0` returns 1.

  # Examples
  ```
  2.compare_to 1  // => 1
  1.compare_to 1  // => 0
  1.compare_to 2  // => -1

  (-0.0).compare_to 0.0 // => -1

  2.compare_to float.NAN // => -1

  float.INFINITY.compare_to 3               // => 1
  float.INFINITY.compare_to float.INFINITY  // => 0
  3.compare_to float.INFINITY               // => -1
  ```
  */
  compare_to other/num -> int:
    #primitive.core.compare_to

  /**
  The absolute value of this number.

  The number -9223372036854775808 (0x8000_0000_0000_0000 or $int.MIN) does
    not have an absolute counterpart.

  # Examples
  ```
  2.abs       // => 2
  (-2).abs    // => 2
  2.0.abs     // => 2.0
  (-2.0).abs  // => 2.0
  (-0.0).abs  // => 0.0

  int.MIN.abs            // => -9223372036854775808
  float.NAN.abs          // => float.NAN
  (-float.INFINITY).abs  // => float.NAN
  ```
  */
  abstract abs -> num

  /**
  Converts this number to a floating point number.

  For very large integers, the conversion may be to the nearest floating
    point number.

  # Examples
  ```
  2.to_float   // => 2.0
  2.1.to_float // => 2.1

  9223372036854775807.to_float  // => 9223372036854775808.0

  ```
  */
  to_float -> float:
    #primitive.core.number_to_float

  /**
  Variant of $(compare_to other).

  Calls $if_equal if this number is equal to $other.

  # Examples
  In the example, `MyTime` implements a lexicographical ordering of seconds
    and nanoseconds using $(compare_to other [--if_equal]) to move on to
    nanoseconds when the seconds component is equal.
  ```
  class MyTime:
    seconds/int
    nanoseconds/int

    constructor .seconds .nanoseconds:

    compare_to other/MyTime -> int:
      return seconds.compare_to other.seconds --if_equal=:
        nanoseconds.compare_to other.nanoseconds
  ```
  */
  compare_to other/num [--if_equal] -> int:
    result := compare_to other
    if result == 0: return if_equal.call
    return result

  /**
  Takes the square root of this number.

  Returns NaN ($float.NAN) for negative numbers (including -0.0).

  # Examples
  ```
  4.sqrt     // => 2
  25.0.sqrt  // => 5
  2.sqrt     // => 1.4142135623730951455
  (-4).sqrt  // => float.NAN
  ```
  */
  abstract sqrt -> float

abstract class int extends num:
  /**
  The maximum integer value.

  The maximum value is equal to:
    * 9223372036854775807
    * 2**63-1
    * 0x7fff_ffff_ffff_ffff
  (** is "to the power of".)
  */
  static MAX ::= 0x7fff_ffff_ffff_ffff

  /**
  The minimum integer value.

  The minimum value is equal to:
    * -9223372036854775808
    * -2**63
    * 0x8000_0000_0000_0000
  (** is "to the power of".)
  */
  static MIN ::= -MAX - 1

  static PARSE_ERR_ ::= "INTEGER_PARSING_ERROR"
  static RANGE_ERR_ ::= "OUT_OF_RANGE"
  static MAX_INT64_DIV_10_ ::= 922337203685477580

  static MAX_INT64_LAST_CHARS_ ::= #[0, 0, 1, 1, 3, 2, 1, 0, 7, 7, 7, 7, 7, 7, 7, 7, 15, 8, 7, 17, 7, 7, 7, 2, 7, 7, 7, 25, 7, 11, 7, 7, 31, 7, 25, 7, 7]

  /**
  Parses the $data as an integer.

  The data must be a $string or $ByteArray.

  The given $radix must be in the range 2 and 36 (inclusive).

  Use slices to parse only a subset of the data (for example `data[..3]`).

  # Errors
  The $data must be a valid integer. That is, it may have a leading "-"
    and must otherwise only contain valid characters as specified by
    the $radix.

  The number represented by $data must be in the 64-bit integer range
    ([$int.MIN, $int.MAX]).

  The $data must not be empty.

  # Examples
  ```
  int.parse "22"           // => 22
  int.parse "-2"           // => -2
  int.parse "007"          // => 7
  int.parse "anno 2017"    // Error.

  int.parse "22" --radix=16       // => 34
  int.parse "a" --radix=16        // => 10
  int.parse "A" --radix=16        // => 10
  ```
  */
  static parse data --radix=10 -> int:
    return parse data --radix=radix --on_error=: throw it

  /** Deprecated. Use $(parse data --radix) with a slice instead. */
  static parse data from/int to/int=data.size --radix=10 -> int:
    return parse data[from..to] --radix=radix --on_error=: throw it

  /**
  Variant of $(parse data from to --radix).

  If the data can't be parsed correctly, returns the result of calling the $on_error
    lambda.
  */
  static parse data --radix=10 [--on_error] -> int?:
    return parse_ data 0 data.size --radix=radix --on_error=on_error

  /**
  Deprecated. Use $(parse data --radix [--on_error]) with a slice instead.
  */
  static parse data from/int to/int=data.size --radix=10 [--on_error] -> int?:
    return parse_ data from to --radix=radix --on_error=on_error

  static parse_ data from/int to/int=data.size --radix=10 [--on_error] -> int?:
    if not 0 <= from < to <= data.size: return on_error.call RANGE_ERR_
    if radix == 10:
      return parse_10_ data from to --on_error=on_error
    else if radix == 16:
      return parse_16_ data from to --on_error=on_error
    else:
      return parse_generic_radix_ radix data from to --on_error=on_error

  static char_to_int_ c/int -> int:
    if '0' <= c <= '9': return c - '0'
    else if 'A' <= c <= 'Z': return 10 + c - 'A'
    else if 'a' <= c <= 'z': return 10 + c - 'a'
    throw PARSE_ERR_

  static parse_generic_radix_ radix/int data from/int to/int [--on_error] -> int?:
    if not 2 <= radix <= 36: throw "INVALID_RADIX"

    max_num := (min radix 10) + '0' - 1
    max_char := radix - 10 + 'a' - 1
    max_char_C := radix - 10 + 'A' - 1
    // The minimum number of characters required to overflow a big number is 13
    // (There are 13 characters in 2 ** 63 base 36).  Therefore we avoid the
    // expensive division for strings with less than 13 characters.
    max_int64_div_radix := (to - from > 12) ? MAX / radix : MAX
    max_last_char := MAX_INT64_LAST_CHARS_[radix]

    return generic_parser_ data from to --on_error=on_error: | char result is_last negative |
      value := 0

      if result > max_int64_div_radix or (result == max_int64_div_radix and (char_to_int_ char) > max_last_char):
        min_last_char := (max_last_char + 1) % radix
        if negative and is_last and (char_to_int_ char) == min_last_char:
          if result == max_int64_div_radix:
            return int.MIN
          else if result == max_int64_div_radix + 1:
            return int.MIN
        return on_error.call RANGE_ERR_

      if '0' <= char <= max_num:
        value = char - '0'
      else if radix > 10 and 'a' <= char <= max_char:
        value = 10 + char - 'a'
      else if radix > 10 and 'A' <= char <= max_char_C:
        value = 10 + char - 'A'
      else:
        return on_error.call PARSE_ERR_
      result *= radix
      result += value
      continue.generic_parser_ result

  static parse_10_ data from/int to/int [--on_error] -> int?:
    return generic_parser_ data from to --on_error=on_error: | char result is_last negative |
      if not '0' <= char <= '9': return on_error.call PARSE_ERR_
      // The max int64 ends with a '7' and the min int64 ends with an '8'
      if result > MAX_INT64_DIV_10_ or (result == MAX_INT64_DIV_10_ and char > '7'):
        if negative and result == MAX_INT64_DIV_10_ and is_last and char == '8':
          return int.MIN
        return on_error.call RANGE_ERR_
      continue.generic_parser_ result * 10 + char - '0'

  static generic_parser_ data from/int to/int [--on_error] [parse_char] -> int?:
    result := 0
    negative := false
    underscore := false
    size := to - from
    size.repeat:
      char := data[from + it]
      if char == '-':
        if it != 0 or size == 1: return on_error.call PARSE_ERR_
        negative = true
      else if char == '_' and not underscore:
        if is_invalid_underscore it size negative:
          return on_error.call PARSE_ERR_
        else:
          underscore = true
      else:
        underscore = false
        is_last := it == size - 1
        result = parse_char.call char result is_last negative
    if negative: result = -result
    return result

  static is_invalid_underscore index size negative:
    // The '_' should not be the first or the last character.
    return (not negative and index == 0) or (negative and index == 1) or index == size - 1

  static parse_16_ data from/int to/int [--on_error] -> int?:
    max_int64_div_radix := MAX / 16

    return generic_parser_ data from to --on_error=on_error: | char result is_last negative |
      if result > max_int64_div_radix or (result == max_int64_div_radix and char > 'f'):
        if negative and is_last and char == '0' and result == max_int64_div_radix + 1:
            return int.MIN
        return on_error.call RANGE_ERR_

      value := hex_digit char: on_error.call PARSE_ERR_
      result <<= 4
      result |= value
      continue.generic_parser_ result

  /** See $super. */
  abstract operator - -> int

  /**
  Negates this number bitwise.

  # Examples
  ```
  ~0  // => -1 (0xffff_ffff_ffff_ffff)
  ~1  // => -2 (0xffff_ffff_ffff_fffe)
  ```
  */
  abstract operator ~ -> int

  /**
  Bitwise-ANDs this number with the $other.

  # Examples
  ```
  1 & 1        // => 1
  1 & 0        // => 0
  0 & 1        // => 0
  0 & 0        // => 0
  293 & 465    // => 257

  0b1111 & 0b1110  // => 14 (0b1110)
  0b0001 & 0b1110  // => 0
  0b0011 & 0b1110  // => 2 (0b10)
  ```
  */
  abstract operator & other/int -> int

  /**
  Bitwise-ORs this number with the $other.

  # Examples
  ```
  1 | 1        // => 1
  1 | 0        // => 1
  0 | 1        // => 1
  0 | 0        // => 0
  293 | 465    // => 501

  0b1100 | 0b0011  // => 15 (0b1111)
  0b1010 | 0b0011  // => 11 (0b1011)
  ```
  */
  abstract operator | other/int -> int

  /**
  Bitwise-XORs this number with the $other.

  # Examples
  ```
  1 ^ 1        // => 0
  1 ^ 0        // => 1
  0 ^ 1        // => 1
  0 ^ 0        // => 0
  293 ^ 465    // => 244

  0b1010 ^ 0b0101  // => 15 (0b1111)
  0b1010 ^ 0b1010  // => 0 (0b0000)
  0b1111 ^ 0b1010  // => 7 (0b0101)
  ```
  */
  abstract operator ^ other/int -> int

  /**
  Right shifts this number with $number_of_bits.

  The left most bit of this number is inserted to the left of the shifted
    bits preserving the sign.

  # Examples
  ```
  16 >> 0  // => 16
  16 >> 1  // => 8
  16 >> 4  // => 1
  16 >> 5  // => 0

  -16 >> 1  // => -8
  -16 >> 4  // => -1
  -16 >> 5  // => -1
  ```
  */
  abstract operator >> number_of_bits/int -> int

  /**
  Right shifts this number with $number_of_bits erasing the sign bit.

  # Examples
  ```
  16 >>> 0  // => 16
  16 >>> 1  // => 8
  16 >>> 4  // => 1
  16 >>> 5  // => 0

  -1 >>> 0    // => -1
  -16 >>> 1   // => 9223372036854775800
  -1 >>> 1    // => 9223372036854775807 (int.MAX)
  -16 >>> 60  // => 15
  -16 >>> 64  // => 0
  ```
  */
  abstract operator >>> number_of_bits/int -> int

  /**
  Left shifts this number with $number_of_bits.

  # Examples
  ```
  0 << 2  // => 0
  1 << 2  // => 4
  1 << 10  // => 1024
  1 << 62  // => 4611686018427387904
  1 << 63  // => -9223372036854775808
  1 << 64  // => 0

  -1 << 2  // => -4
  -1 << 9  // => -512
  -1 << 63 // => -9223372036854775808
  -1 << 0  // => 0
  ```
  */
  abstract operator << number_of_bits/int -> int

  /**
  Variant of $stringify.
  Unlike string interpolation with base 8 or 16, negative
    numbers are rendered in a straight-forward way with a
    '-' character at the start.

  Supports $radix 2 to 36.

  # Examples
  ```
  0.stringify 2   // => 0
  7.stringify 2   // => 111
  32.stringify 32 // => 10
  42.stringify 16 // => 2a
  -1.stringify 8  // => -1
  -9.stringify 8  // => -11
  35.stringify 36 // => z
  ```
  */
  stringify radix/int:
    #primitive.core.int64_to_string

  /** See $super. */
  abs -> int:
    return sign == -1 ? -this : this

  /** See $super. */
  to_int -> int:
    return this

  /** See $super. */
  sign -> int:
    return 0 == this ? 0 : (0 > this ? -1 : 1)

  /**
  Sign-extend an n-bit two's complement number to a full (64 bit)
    signed Toit integer.

  # Examples
  ```
  255.sign_extend --bits=8  // => -1
  128.sign_extend --bits=8  // => -128
  127.sign_extend --bits=8  // => 127
  ```
  */
  sign_extend --bits/int -> int:
    if not 1 <= bits <= 63:
      if bits == 64: return this
      throw "OUT_OF_RANGE"
    if (this >> (bits - 1)) & 1 == 0:
      return this
    return this | ~((1 << bits) - 1)

  /**
  Extract a bit-field from an integer.
  Bits are numbered from zero with zero being the least significant bit.
  Can be written lsb-first and non-inclusive, which matches the normal
    use of the slice operator.
  Following Verilog and most data sheets, the bit indexes can be written
    MSB-first, in which case they are inclusive

  #Examples.
  x[3..1]                 // Equivalent to Verilog x[3:1].
  x[1..4]                 // Same as the above
  0b1100_1010_0011[4..8]  // => 0b1010
  0b1100_1010_0011[7..4]  // => 0b1010, equivalent to Verilog [7:4]

  // Extract a signed 7-bit field x[18:12].
  f := x[18..12].sign_extend --bits=7
  */
  operator [..] --from/int --to/int -> int:
    shift / int := ?
    bits / int := ?
    if from >= to:
      // Verilog-style.
      if not 0 <= to <= from <= 63: throw "OUT_OF_RANGE"
      bits = from + 1 - to
      shift = to
    else:
      // Slice-style.
      if not 0 <= from <= to <= 64: throw "OUT_OF_RANGE"
      bits = to - from
      shift = from
    if bits == 64: return this
    return (this >> shift) & ((1 << bits) - 1)

  /**
  The hash code of this number.
  */
  hash_code -> int:
    return this

  /** See $super. */
  sqrt -> float:
    return to_float.sqrt

  /**
  Whether this number is a power of two.

  A number is a power of two if here exists a number `n` such that the number
    is equal to 2**n.
  (** is "to the power of".)

  # Examples
  ```
  1.is_power_of_two     // => true
  2.is_power_of_two     // => true
  4.is_power_of_two     // => true
  1096.is_power_of_two  // => true

  0.is_power_of_two     // => false
  (-2).is_power_of_two  // => false
  1.is_power_of_two     // => false
  14.is_power_of_two    // => false
  ```
  */
  is_power_of_two -> bool:
    return (this & this - 1) == 0 and this != 0

  /**
  Whether this number is aligned with $n.

  This number and the given $n must be a power of 2 or 0.

  # Examples
  ```
  8.is_aligned 2         // => true
  4.is_aligned 4         // => true
  16384.is_aligned 4096  // => true
  0.is_aligned 4096      // => true

  2.is_aligned 1024  // => false

  2.is_aligned 3     // Error.
  3.is_aligned 2     // Error.
    ```
  */
  is_aligned n/int -> bool:
    if not n.is_power_of_two: throw "INVALID ARGUMENT"
    return (this & n - 1) == 0

  /**
  Calls the given $block a number of times corresponding to the value of
    this number.

  If the number is negative, then the given block is not called.

  # Examples
  ```
  count := 0
  3.repeat: count++
  print count  // >> 3

  count = 0
  0.repeat: count++
  print count  // >> 0

  count = 0
  (-1).repeat: count++
  print count  // >> 0
  ```
  */
  repeat [block] -> none:
    for index := 0; index < this; index++: block.call index

class SmallInteger_ extends int:
  /** See $super. */
  operator + other:
    #primitive.core.smi_add:
      return other.add_from_small_integer_ this

  /** See $super. */
  operator - other:
    #primitive.core.smi_subtract:
      return other.subtract_from_small_integer_ this

  /** See $super. */
  operator * other:
    #primitive.core.smi_multiply:
      return other.multiply_from_small_integer_ this

  /** See $super. */
  operator / other:
    #primitive.core.smi_divide:
      if it == "DIVISION_BY_ZERO": throw it
      return other.divide_from_small_integer_ this

  /** See $super. */
  operator % other:
    #primitive.core.smi_mod:
      if it == "DIVISION_BY_ZERO": throw it
      return other.mod_from_small_integer_ this

  /** See $super. */
  operator == other -> bool:
    #primitive.core.smi_equals:
      return other is num and other.equals_from_small_integer_ this

  /** See $super. */
  operator < other -> bool:
    #primitive.core.smi_less_than:
      return other.less_than_from_small_integer_ this

  /** See $super. */
  operator <= other -> bool:
    #primitive.core.smi_less_than_or_equal:
      return other.less_than_or_equal_from_small_integer_ this

  /** See $super. */
  operator > other -> bool:
    #primitive.core.smi_greater_than:
      return other.greater_than_from_small_integer_ this

  /** See $super. */
  operator >= other -> bool:
    #primitive.core.smi_greater_than_or_equal:
      return other.greater_than_or_equal_from_small_integer_ this

  /** See $super. */
  operator - -> int:
    #primitive.core.smi_unary_minus

  /** See $super. */
  operator ~ -> int:
    #primitive.core.smi_not

  /** See $super. */
  operator & other -> int:
    #primitive.core.smi_and:
      return other.and_from_small_integer_ this

  /** See $super. */
  operator | other -> int:
    #primitive.core.smi_or:
      return other.or_from_small_integer_ this

  /** See $super. */
  operator ^ other -> int:
    #primitive.core.smi_xor:
      return other.xor_from_small_integer_ this

  /** See $super. */
  operator >> number_of_bits -> int:
    #primitive.core.smi_shift_right

  /** See $super. */
  operator >>> number_of_bits -> int:
    #primitive.core.smi_unsigned_shift_right

  /** See $super. */
  operator << number_of_bits -> int:
    #primitive.core.smi_shift_left

  /** See $super. */
  stringify -> string:
    #primitive.core.smi_to_string_base_10

  /** See $super. */
  repeat [block] -> none:
    #primitive.intrinsics.smi_repeat:
      // The intrinsic only fails if we cannot call the block with a single
      // argument. We force this to throw by doing the same here.
      block.call null

  // Double dispatch support for binary operations.

  add_from_float_ other:
    return other + to_float

  subtract_from_float_ other:
    return other - to_float

  multiply_from_float_ other:
    return other * to_float

  divide_from_float_ other:
    return other / to_float

  mod_from_float_ other:
    return other % to_float

  equals_from_float_ other:
    return other == to_float

  less_than_from_float_ other:
    return other < to_float

  less_than_or_equal_from_float_ other:
    return other <= to_float

  greater_than_from_float_ other:
    return other > to_float

  greater_than_or_equal_from_float_ other:
    return other >= to_float

class LargeInteger_ extends int:
  /** See $super. */
  operator + other:
    #primitive.core.large_integer_add:
      return other.add_from_large_integer_ this

  /** See $super. */
  operator - other:
    #primitive.core.large_integer_subtract:
      return other.subtract_from_large_integer_ this

  /** See $super. */
  operator * other:
    #primitive.core.large_integer_multiply:
      return other.multiply_from_large_integer_ this

  /** See $super. */
  operator / other:
    #primitive.core.large_integer_divide:
      if it == "DIVISION_BY_ZERO": throw it
      return other.divide_from_large_integer_ this

  /** See $super. */
  operator % other:
    #primitive.core.large_integer_mod:
      if it == "DIVISION_BY_ZERO": throw it
      return other.mod_from_large_integer_ this

  /** See $super. */
  operator == other -> bool:
    #primitive.core.large_integer_equals:
      return other is num and other.equals_from_large_integer_ this

  /** See $super. */
  operator < other -> bool:
    #primitive.core.large_integer_less_than:
      return other.less_than_from_large_integer_ this

  /** See $super. */
  operator <= other -> bool:
    #primitive.core.large_integer_less_than_or_equal:
      return other.less_than_or_equal_from_large_integer_ this

  /** See $super. */
  operator > other -> bool:
    #primitive.core.large_integer_greater_than:
      return other.greater_than_from_large_integer_ this

  /** See $super. */
  operator >= other -> bool:
    #primitive.core.large_integer_greater_than_or_equal:
      return other.greater_than_or_equal_from_large_integer_ this

  /** See $super. */
  operator - -> int:
    #primitive.core.large_integer_unary_minus

  /** See $super. */
  operator ~ -> int:
    #primitive.core.large_integer_not

  /** See $super. */
  operator & other -> int:
    #primitive.core.large_integer_and:
      return other.and_from_large_integer_ this

  /** See $super. */
  operator | other -> int:
    #primitive.core.large_integer_or:
      return other.or_from_large_integer_ this

  /** See $super. */
  operator ^ other -> int:
    #primitive.core.large_integer_xor:
      return other.xor_from_large_integer_ this

  /** See $super. */
  operator >> number_of_bits -> int:
    #primitive.core.large_integer_shift_right

  /** See $super. */
  operator >>> number_of_bits -> int:
    #primitive.core.large_integer_unsigned_shift_right

  /** See $super. */
  operator << number_of_bits -> int:
    #primitive.core.large_integer_shift_left

  /** Se $super. */
  stringify -> string:
    return stringify 10

  /** See $super */
  to_int -> int: return this

  add_from_float_ other:
    return other + to_float

  subtract_from_float_ other:
    return other - to_float

  multiply_from_float_ other:
    return other * to_float

  divide_from_float_ other:
    return other / to_float

  mod_from_float_ other:
    return other % to_float

  equals_from_float_ other:
    return other == to_float

  less_than_from_float_ other:
    return other < to_float

  less_than_or_equal_from_float_ other:
    return other <= to_float

  greater_than_from_float_ other:
    return other > to_float

  greater_than_or_equal_from_float_ other:
    return other >= to_float

class float extends num:

  /**
  A not-a-number representation.

  Use $is_nan to check for not-a-number.

  # Advanced
  There are multiple representations of not-a-number. For example, the
  following produces another not-a-number representation:
  ```
  float.from_bits (float.NAN.bits + 1)
  ```
  Comparing the above representation with this constant will result in false:
  ```
  float.NAN == float.from_bits (float.NAN.bits + 1)  // => false
  ```
  It is therefore important to use $is_nan to check for not-a-number.
  */
  static NAN          /float ::= 0.0 / 0.0
  /**
  The infinity representation.
  */
  static INFINITY     /float ::= 1.0 / 0.0
  /**
  The maximum finite float.
  */
  static MAX_FINITE   /float ::= 0x1F_FFFF_FFFF_FFFFp971
  /**
  The minimum positive float.
  */
  static MIN_POSITIVE /float ::= 0x1p-1074

/**
  Parses the $data to a float.

  The data must be a $string or $ByteArray.

  Returns the nearest floating point number for $data not representable by any
    floating point number.

  # Errors
  The $data must contain only a valid float. Trailing junk is not allowed.

  The $data must not be empty.

  # Examples
  ```
  float.parse "2"          // => 2.0
  float.parse "2.0"        // => 2.0
  float.parse "2.1"        // => 2.1000000000000000888
  float.parse "007"        // => 7.0
  float.parse "anno 2017"  // Error.
  ```
  */
  static parse data -> float:
    return parse_ data 0 data.size

  /**
  Deprecated. Use $(parse data) with slices instead.
  */
  static parse data from/int to/int=data.size -> float:
    return parse_ data from to

  static parse_ data from/int to/int -> float:
    #primitive.core.float_parse:
      if it == "ERROR": throw "FLOAT_PARSING_ERROR"
      throw it

  /**
  Returns the sign of this instance.

  The sign is:
  - -1 for negative numbers, and for -0.0
  - 0 for 0.0
  - 1 for positive numbers.
  */
  sign -> int:
    #primitive.core.float_sign

  /** See $super. */
  operator - -> float:
    #primitive.core.float_unary_minus

  /** See $super. */
  operator + other -> float:
    #primitive.core.float_add:
      return other.add_from_float_ this

  /** See $super. */
  operator - other -> float:
    #primitive.core.float_subtract:
      return other.subtract_from_float_ this

  /** See $super. */
  operator * other -> float:
    #primitive.core.float_multiply:
      return other.multiply_from_float_ this

  /** See $super. */
  operator / other -> float:
    #primitive.core.float_divide:
      return other.divide_from_float_ this

  /** See $super. */
  operator % other -> float:
    #primitive.core.float_mod:
      return other.mod_from_float_ this

  /** See $super. */
  operator == other -> bool:
    #primitive.core.float_equals:
      return other is num and other.equals_from_float_ this

  /** See $super. */
  operator < other -> bool:
    #primitive.core.float_less_than:
      return other.less_than_from_float_ this

  /** See $super. */
  operator <= other -> bool:
    #primitive.core.float_less_than_or_equal:
      return other.less_than_or_equal_from_float_ this

  /** See $super. */
  operator > other -> bool:
    #primitive.core.float_greater_than:
      return other.greater_than_from_float_ this

  /** See $super. */
  operator >= other -> bool:
    #primitive.core.float_greater_than_or_equal:
      return other.greater_than_or_equal_from_float_ this

  /** See $super. */
  abs -> float:
    return sign == -1 ? -this : this

  /** See $super. */
  sqrt -> float:
    #primitive.core.float_sqrt

  /**
  Rounds this number to the nearest integer.

  # Errors
  This number must not be a NaN ($float.NAN) or negative and positive infinity ($float.INFINITY).

  # Examples
  ```
  3.1.round  // => 3
  3.4.round  // => 3
  3.5.round  // => 4
  3.9.round  // => 4

  (-5.1).round  // => -5
  (-5.4).round  // => -5
  (-5.5).round  // => -6
  (-5.9).round  // => -6

  (-0.0).round  // => 0
  2.sqrt.round  // => 1
  ```
  */
  round -> int:
    rounded_float := round_ --precision=0
    return rounded_float.to_int

  round_ --precision -> float:
    #primitive.core.float_round

  /** Deprecated. */
  round --precision -> float:
    return round_ --precision=precision

  /**
  See $super.

  If $precision is null format "%.20lg" in C++ is used.
  If $precision is an integer format "%.*lf" in C++ is used.

  # Errors
  The $precision must be an integer in range [0..64] or null.
  */
  stringify precision=null -> string:
    #primitive.core.float_to_string

  /**
  Whether this number is a NaN ($float.NAN).

  # Examples
  ```
  float.NAN.is_nan                               // => true
  (-1).sqrt.is_nan                               // => true
  (float.from_bits (float.NAN.bits + 1)).is_nan  // => true

  2.0.is_nan                 // => false
  2.sqrt.is_nan              // => false
  float.INFINITY.is_nan      // => false
  float.MAX_FINITE.is_nan    // => false
  float.MIN_POSITIVE.is_nan  // => false
  ```
  */
  is_nan -> bool:
    #primitive.core.float_is_nan

  /**
  Whether this number is finite.

  # Examples
  ```
  2.0.is_finite                 // => true
  (-9001.0).is_finite           // => true
  2.sqrt.is_finite              // => true
  float.MAX_FINITE.is_finite    // => true
  float.MIN_POSITIVE.is_finite  // => true

  float.NAN.is_finite       // => false
  (-1).sqrt.is_finite       // => false
  float.INFINITY.is_finite  // => false
  ```
  */
  is_finite -> bool:
    #primitive.core.float_is_finite

  /** See $super. */
  to_int -> int:
    #primitive.core.number_to_integer

  /**
  Converts this number to its bit representation.

  A $float corresponds to the IEEE 754 double precision (binary64) type. It has
    64 bits, of which 1 bit is used as sign, 11 for the exponent, and 52 for the
    significant.

  This function is the inverse of $from_bits.
  */
  bits -> int:
    #primitive.core.float_to_raw

  /**
  Converts this instance to a 32-bit floating-point number and returns its bits.

  # Advanced
  Internally converts this instance to a IEEE 754 single precision (binary32) value
    and returns its bits. The format consists of 1 sign bit, 8 exponent bits, and
    23 significand bits.
  The conversion from 64-bit floating-point number (this instance) to a 32-bit
    number loses in precision and range. If this instance is out of range it is
    mapped to the IEEE 754 single precision infinity value which has bit-pattern
    0x7F80_0000 (positive) or 0xFF80_0000 (negative).
  */
  bits32 -> int:
    #primitive.core.float_to_raw32

  /**
  Converts to $raw bit pattern to the corresponding $float.

  This function is the inverse of $bits.
  */
  static from_bits raw/int -> float:
    #primitive.core.raw_to_float

  /**
  Converts the given $raw bits to a 32-bit floating-point number and
    returns the corresponding $float.

  Given the $raw bits of an IEEE 754 single-precision (binary32)
    floating-point number, constructs the corresponding value, and
    returns it as a $float.

  This function is the inverse of $bits32.
  */
  static from_bits32 raw/int -> float:
    #primitive.core.raw32_to_float

  // Double dispatch support for binary operations.

  add_from_small_integer_ other:
    return other.to_float + this

  subtract_from_small_integer_ other:
    return other.to_float - this

  multiply_from_small_integer_ other:
    return other.to_float * this

  divide_from_small_integer_ other:
    return other.to_float / this

  mod_from_small_integer_ other:
    return other.to_float % this

  equals_from_small_integer_ other:
    return other.to_float == this

  less_than_from_small_integer_ other:
    return other.to_float < this

  less_than_or_equal_from_small_integer_ other:
    return other.to_float <= this

  greater_than_from_small_integer_ other:
    return other.to_float > this

  greater_than_or_equal_from_small_integer_ other:
    return other.to_float >= this

  add_from_large_integer_ other:
    return other.to_float + this

  subtract_from_large_integer_ other:
    return other.to_float - this

  multiply_from_large_integer_ other:
    return other.to_float * this

  divide_from_large_integer_ other:
    return other.to_float / this

  mod_from_large_integer_ other:
    return other.to_float % this

  equals_from_large_integer_ other:
    return other.to_float == this

  less_than_from_large_integer_ other:
    return other.to_float < this

  less_than_or_equal_from_large_integer_ other:
    return other.to_float <= this

  greater_than_from_large_integer_ other:
    return other.to_float > this

  greater_than_or_equal_from_large_integer_ other:
    return other.to_float >= this
