// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..io as io

/**
A number.
This is an abstract super class for $int and $float.
See also https://docs.toit.io/language/math.
*/
abstract class num implements Comparable:
  static PARSE-ERR_ ::= "NUMBER_PARSING_ERROR"

  equals-from-float_ other/float -> bool: return false
  equals-from-small-integer_ other/int -> bool: return false
  equals-from-large-integer_ other/int -> bool: return false

  /**
  Converts this number to an integer.

  # Errors
  This number must be inside the 64-bit integer range ([$int.MIN, $int.MAX]).
  This number must be a valid number and not a NaN ($float.NAN).

  # Examples
  ```
  42.to-int  // => 42

  (100.0).to-int   // => 100
  (-1.123).to-int  // => -1

  float.MAX-FINITE.to-int  // Error.
  float.INFINITY.to-int    // Error.
  float.NAN.to-int         // Error.
  ```
  */
  abstract to-int -> int

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

  float.MAX-FINITE < float.INFINITY  // => true
  float.NAN < float.INFINITY  // => false
  float.INFINITY < float.NAN  // => false
  ```
  */
  abstract operator < other/num -> bool

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

  float.MAX-FINITE <= float.INFINITY  // => true
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

  float.MAX-FINITE > float.INFINITY  // => false
  float.NAN > float.INFINITY  // => false
  float.INFINITY > float.NAN  // => false
  ```
  */
  abstract operator > other/num -> bool

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

  float.MAX-FINITE >= float.INFINITY  // => false
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
  abstract operator + other/num

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
  abstract operator - other/num

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
  abstract operator * other/num

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
  abstract operator / other/num

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
  abstract operator % other/num

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
    `0.0.compare-to -0.0` returns 1.

  # Examples
  ```
  2.compare-to 1  // => 1
  1.compare-to 1  // => 0
  1.compare-to 2  // => -1

  (-0.0).compare-to 0.0 // => -1

  2.compare-to float.NAN // => -1

  float.INFINITY.compare-to 3               // => 1
  float.INFINITY.compare-to float.INFINITY  // => 0
  3.compare-to float.INFINITY               // => -1
  ```
  */
  compare-to other/num -> int:
    #primitive.core.compare-to

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
  2.to-float   // => 2.0
  2.1.to-float // => 2.1

  9223372036854775807.to-float  // => 9223372036854775808.0

  ```
  */
  to-float -> float:
    #primitive.core.number-to-float

  /**
  Variant of $(compare-to other).

  Calls $if-equal if this number is equal to $other.

  # Examples
  In the example, `MyTime` implements a lexicographical ordering of seconds
    and nanoseconds using $(compare-to other [--if-equal]) to move on to
    nanoseconds when the seconds component is equal.
  ```
  class MyTime:
    seconds/int
    nanoseconds/int

    constructor .seconds .nanoseconds:

    compare-to other/MyTime -> int:
      return seconds.compare-to other.seconds --if-equal=:
        nanoseconds.compare-to other.nanoseconds
  ```
  */
  compare-to other/num [--if-equal] -> int:
    result := compare-to other
    if result == 0: return if-equal.call
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

  /**
  Parses the given $data as a number.

  Tries to parse the $data as an integer first, and if that fails, as a float.

  See $int.parse and $float.parse.
  */
  static parse data/io.Data -> num:
    return parse data --if-error=: throw it

  /** Deprecated. Use $(parse data [--if-error]) instead. */
  static parse data/io.Data [--on-error] -> num?:
    return parse data --if-error=on-error

  /**
  Variant of $(parse data).

  If the data can't be parsed correctly, returns the result of calling the $if-error block.
  */
  static parse data/io.Data [--if-error] -> num?:
    return int.parse data --if-error=:
      return float.parse data --if-error=:
        return if-error.call PARSE-ERR_

  /**
  Converts this number to a well-defined string.
  */
  abstract to-string -> string

  /** See $super. */
  stringify -> string:
    return to-string

/**
A 64 bit integer.
Ints are always 64 bit two's complement signed values between $int.MIN and
  $int.MAX.  Overflow is silent.
This is a fully fledged class, not a 'primitive type'.
Ints are immutable objects.
See also https://docs.toit.io/language/math.
*/
abstract class int extends num:
  /**
  The maximum integer value.

  The maximum value is equal to:
  * 9223372036854775807
  * 2**63-1  (** is "to the power of")
  * 0x7fff_ffff_ffff_ffff
  */
  static MAX ::= 0x7fff_ffff_ffff_ffff

  /**
  The minimum integer value.

  The minimum value is equal to:
  * -9223372036854775808
  * -2**63 (** is "to the power of").
  * 0x8000_0000_0000_0000
  */
  static MIN ::= -MAX - 1

  /** The minimum signed 8-bit integer value. */
  static MIN-8 ::= -MAX-8 - 1
  /** The maximum signed 8-bit integer value. */
  static MAX-8 ::= 0x7F
  /** The minimum signed 16-bit integer value. */
  static MIN-16 ::= -MAX-16 - 1
  /** The maximum signed 16-bit integer value. */
  static MAX-16 ::= 0x7FFF
  /** The minimum signed 24-bit integer value. */
  static MIN-24 ::= -MAX-24 - 1
  /** The maximum signed 24-bit integer value. */
  static MAX-24 ::= 0x7F_FFFF
  /** The minimum signed 32-bit integer value. */
  static MIN-32 ::= -MAX-32 - 1
  /** The maximum signed 32-bit integer values. */
  static MAX-32 ::= 0x7FFF_FFFF

  /** The maximum unsigned 8-bit integer values. */
  static MAX-U8 ::= 0xFF
  /** The maximum unsigned 16-bit integer values. */
  static MAX-U16 ::= 0xFFFF
  /** The maximum unsigned 24-bit integer values. */
  static MAX-U24 ::= 0xFF_FFFF
  /** The maximum unsigned 32-bit integer values. */
  static MAX-U32 ::= 0xFFFF_FFFF


  static PARSE-ERR_ ::= "INTEGER_PARSING_ERROR"
  static RANGE-ERR_ ::= "OUT_OF_RANGE"
  static MAX-INT64-DIV-10_ ::= 922337203685477580

  static MAX-INT64-LAST-CHARS_ ::= #[0, 0, 1, 1, 3, 2, 1, 0, 7, 7, 7, 7, 7, 7, 7, 7, 15, 8, 7, 17, 7, 7, 7, 2, 7, 7, 7, 25, 7, 11, 7, 7, 31, 7, 25, 7, 7]

  /**
  Parses the $data as an integer.

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
  static parse data/io.Data --radix/int?=null -> int:
    return parse_ data 0 data.byte-size --radix=radix --if-error=: throw it

  /** Deprecated. Use $(parse data --radix) with a slice instead. */
  static parse data/io.Data from/int to/int=data.byte-size --radix/int?=null -> int:
    return parse_ data from to --radix=radix --if-error=: throw it

  /** Deprecated. Use $(parse data --radix [--if-error]) instead. */
  static parse data/io.Data --radix/int?=null [--on-error] -> int?:
    return parse_ data 0 data.byte-size --radix=radix --if-error=on-error

  /**
  Variant of $(parse data from to --radix).

  If the data can't be parsed correctly, returns the result of calling the $if-error block.
  */
  static parse data/io.Data --radix/int?=null [--if-error] -> int?:
    return parse_ data 0 data.byte-size --radix=radix --if-error=if-error

  /**
  Deprecated. Use $(parse data --radix [--if-error]) with a slice instead.
  */
  static parse data/io.Data from/int to/int=data.byte-size --radix/int?=null [--on-error] -> int?:
    return parse_ data from to --radix=radix --if-error=on-error

  static parse_ data/io.Data from/int to/int=data.byte-size --radix/int? [--if-error] -> int?:
    negative := false
    if radix == null:
      radix = 10
      if to - from > 2:
        byte0 := data.byte-at from
        byte1 := data.byte-at from + 1
        byte2 := data.byte-at from + 2
        if byte0 == '0' and (byte1 == 'x' or byte1 == 'X'):
          radix = 16
          from += 2
          if byte2 == '-':
            return if-error.call PARSE-ERR_
        else if byte0 == '0' and (byte1 == 'b' or byte1 == 'B'):
          radix = 2
          from += 2
          if byte2 == '-':
            return if-error.call PARSE-ERR_
        else if to - from > 3:
          byte3 := data.byte-at from + 3
          if byte0 == '-' and byte1 == '0' and (byte2 == 'x' or byte2 == 'X'):
            negative = true
            radix = 16
            from += 3
            if byte3 == '-':
              return if-error.call PARSE-ERR_
          else if byte0 == '-' and byte1 == '0' and (byte2 == 'b' or byte2 == 'B'):
            negative = true
            radix = 2
            from += 3
            if byte3 == '-':
              return if-error.call PARSE-ERR_

    if radix == 10:
      return parse-10_ data from to --if-error=if-error
    else if radix == 16:
      return parse-16_ data from to --negative=negative --if-error=if-error
    else:
      return parse-generic-radix_ radix data from to --negative=negative --if-error=if-error

  static char-to-int_ c/int -> int:
    if '0' <= c <= '9': return c - '0'
    else if 'A' <= c <= 'Z': return 10 + c - 'A'
    else if 'a' <= c <= 'z': return 10 + c - 'a'
    throw PARSE-ERR_

  static parse-generic-radix_ radix/int data/io.Data from/int to/int --negative/bool [--if-error] -> int?:
    if not 2 <= radix <= 36: throw "INVALID_RADIX"

    max-num := (min radix 10) + '0' - 1
    max-char := radix - 10 + 'a' - 1
    max-char-C := radix - 10 + 'A' - 1
    // The minimum number of characters required to overflow a big number is 13
    // (There are 13 characters in 2 ** 63 base 36).  Therefore we avoid the
    // expensive division for strings with less than 13 characters.
    max-int64-div-radix := (to - from > 12) ? MAX / radix : MAX
    max-last-char := MAX-INT64-LAST-CHARS_[radix]

    return generic-parser_ data from to --negative=negative --if-error=if-error: | char result is-last negative |
      value := 0

      if result > max-int64-div-radix or (result == max-int64-div-radix and (char-to-int_ char) > max-last-char):
        min-last-char := (max-last-char + 1) % radix
        if negative and is-last and (char-to-int_ char) == min-last-char:
          if result == max-int64-div-radix:
            return int.MIN
          else if result == max-int64-div-radix + 1:
            return int.MIN
        return if-error.call RANGE-ERR_

      if '0' <= char <= max-num:
        value = char - '0'
      else if radix > 10 and 'a' <= char <= max-char:
        value = 10 + char - 'a'
      else if radix > 10 and 'A' <= char <= max-char-C:
        value = 10 + char - 'A'
      else:
        return if-error.call PARSE-ERR_
      result *= radix
      result += value
      continue.generic-parser_ result

  static parse-10_ data/io.Data from/int to/int [--if-error] -> int?:
    #primitive.core.int-parse:
      if it == "WRONG_BYTES_TYPE":
        return parse-10_ (ByteArray.from data) from to --if-error=if-error
      else:
        return generic-parser_ data from to --negative=false --if-error=if-error: | char result is-last negative |
          if not '0' <= char <= '9': return if-error.call PARSE-ERR_
          // The max int64 ends with a '7' and the min int64 ends with an '8'
          if result > MAX-INT64-DIV-10_ or (result == MAX-INT64-DIV-10_ and char > '7'):
            if negative and result == MAX-INT64-DIV-10_ and is-last and char == '8':
              return int.MIN
            return if-error.call RANGE-ERR_
          continue.generic-parser_ result * 10 + char - '0'

  static generic-parser_ data from/int to/int --negative/bool [--if-error] [parse-char] -> int?:
    result := 0
    underscore := false
    size := to - from
    if size == 0: return if-error.call PARSE-ERR_
    size.repeat:
      char := data[from + it]
      if char == '-':
        if it != 0 or size == 1: return if-error.call PARSE-ERR_
        if negative: return if-error.call PARSE-ERR_
        negative = true
      else if char == '_' and not underscore:
        if is-invalid-underscore_ it size negative:
          return if-error.call PARSE-ERR_
        else:
          underscore = true
      else:
        underscore = false
        is-last := it == size - 1
        result = parse-char.call char result is-last negative
    if negative: result = -result
    return result

  static is-invalid-underscore_ index size negative:
    // The '_' should not be the first or the last character.
    return (not negative and index == 0) or (negative and index == 1) or index == size - 1

  static parse-16_ data from/int to/int --negative/bool [--if-error] -> int?:
    max-int64-div-radix := MAX / 16

    return generic-parser_ data from to --negative=negative --if-error=if-error: | char result is-last negative |
      if result > max-int64-div-radix or (result == max-int64-div-radix and char > 'f'):
        if negative and is-last and char == '0' and result == max-int64-div-radix + 1:
            return int.MIN
        return if-error.call RANGE-ERR_

      value := hex-char-to-value char --if-error=(: if-error.call PARSE-ERR_)
      result <<= 4
      result |= value
      continue.generic-parser_ result

  /** See $super. */
  abstract operator - -> int

  /**
  Negates this integer bitwise.

  # Examples
  ```
  ~0  // => -1 (0xffff_ffff_ffff_ffff)
  ~1  // => -2 (0xffff_ffff_ffff_fffe)
  ```
  */
  abstract operator ~ -> int

  /**
  Bitwise-ANDs this integer with the $other.

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
  Bitwise-ORs this integer with the $other.

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
  Bitwise-XORs this integer with the $other.

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
  Right shifts this integer with $number-of-bits.

  The left-most bit of this integer is inserted to the left of the shifted
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
  abstract operator >> number-of-bits/int -> int

  /**
  Right shifts this integer with $number-of-bits, erasing the sign bit.

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
  abstract operator >>> number-of-bits/int -> int

  /**
  Left shifts this integer with $number-of-bits.

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
  abstract operator << number-of-bits/int -> int

  /**
  Variant of $(stringify).
  Unlike string interpolation with base 2, 8, or 16, negative
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
  to-string --radix/int -> string:
    #primitive.core.int64-to-string

  /** Deprecated. Use $(to-string --radix) instead. */
  stringify radix/int -> string:
    #primitive.core.int64-to-string

  /**
  Variant of $(stringify).

  Treats the number as an unsigned 64-bit integer.
  */
  to-string --uint64/True -> string:
    return stringify-uint64_ this

  /** Deprecated. Use $(to-string --uint64) instead. */
  stringify --uint64/True -> string:
    return stringify-uint64_ this

  static stringify-uint64_ number/int -> string:
    #primitive.core.uint64-to-string

  /** See $super. */
  abs -> int:
    return sign == -1 ? -this : this

  /** See $super. */
  to-int -> int:
    return this

  /** See $super. */
  sign -> int:
    return 0 == this ? 0 : (0 > this ? -1 : 1)

  /**
  Sign-extend an n-bit two's complement number to a full (64 bit)
    signed Toit integer.

  # Examples
  ```
  255.sign-extend --bits=8  // => -1
  128.sign-extend --bits=8  // => -128
  127.sign-extend --bits=8  // => 127
  ```
  */
  sign-extend --bits/int -> int:
    if not 1 <= bits <= 63:
      if bits == 64: return this
      throw "OUT_OF_RANGE"
    if (this >> (bits - 1)) & 1 == 0:
      return this
    return this | ~((1 << bits) - 1)

  /**
  The hash code of this number.
  */
  hash-code -> int:
    return this

  /** See $super. */
  sqrt -> float:
    return to-float.sqrt

  /**
  Whether this integer is a power of two.

  An integer is a power of two if there exists a number `n` such that the integer
    is equal to 2**n.
  (** is "to the power of".)

  # Examples
  ```
  1.is-power-of-two     // => true
  2.is-power-of-two     // => true
  4.is-power-of-two     // => true
  1096.is-power-of-two  // => true

  0.is-power-of-two     // => false
  (-2).is-power-of-two  // => false
  1.is-power-of-two     // => false
  14.is-power-of-two    // => false
  ```
  */
  is-power-of-two -> bool:
    return (this & this - 1) == 0 and this != 0

  /**
  Whether this integer is aligned with $n.

  The given $n must be a power of 2.

  # Examples
  ```
  8.is-aligned 2         // => true
  4.is-aligned 4         // => true
  16384.is-aligned 4096  // => true
  0.is-aligned 4096      // => true

  2.is-aligned 1024  // => false
  3.is-aligned 2     // => false.

  2.is-aligned 3     // Error.
    ```
  */
  is-aligned n/int -> bool:
    if not n.is-power-of-two: throw "INVALID ARGUMENT"
    return (this & n - 1) == 0

  /**
  Calls the given $block a number of times corresponding to the value of
    this integer.

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

  /**
  Returns the number of initial zeros in the binary representation of the
    integer.
  The integer is treated as an unsigned 64 bit number.  Thus
    it returns 0 if called on a negative integer.

  # Examples
  ```
  (0x00FF).count-leading-zeros  // => 56
  (0x0025).count-leading-zeros  // => 58
  (0).count-leading-zeros       // => 64
  int.MIN.count-leading-zeros   // => 0
  int.MAX.count-leading-zeros   // => 1
  ```
  */
  count-leading-zeros -> int:
    #primitive.core.count-leading-zeros

  /**
  Returns the number of trailing zeros in the binary representation of the
    integer.
  The integer is treated as an unsigned 64 bit number.
    Thus it returns 1 if called on -2.

  # Examples
  ```
  (0b101000).count-trailing-zeros   // => 3
  (0b101100).count-trailing-zeros   // => 2
  (0b101010).count-trailing-zeros   // => 1
  (0b101101).count-trailing-zeros   // => 0
  (0).count-trailing-zeros          // => 64
  int.MIN.count-trailing-zeros      // => 63
  int.MAX.count-trailing-zeros      // => 0
  ```
  */
  count-trailing-zeros -> int:
    if this == 0: return 64
    value := this ^ (this - 1)
    return 63 - value.count-leading-zeros

  /**
  Returns the number of ones in the binary representation of the integer.
  The integer is treated as a 64 bit number.
    Thus it returns 64 if called on -1.

  # Examples
  ```
  (0b100001).population-count  // => 2
  (0b101100).population-count  // => 3
  (0b101110).population-count  // => 4
  (0b101111).population-count  // => 5
  (0).population-count         // => 0
  (-1).population-count        // => 64
  int.MIN.population-count     // => 1
  int.MAX.population-count     // => 63
  ```
  */
  population-count -> int:
    #primitive.core.popcount

  /**
  Counts the number of ones in the binary representation of the integer.
  Returns 1 if the number is odd, zero if the number is even.
  The integer is treated as a 64 bit number.
    Thus it returns 0 if called on -1.

  # Examples
  ```
  (0b101101).parity  // => 0
  (0b101100).parity  // => 1
  (0b101110).parity  // => 0
  (0b101111).parity  // => 1
  (0).parity         // => 0
  (-1).parity        // => 0
  int.MIN.parity     // => 1
  int.MAX.parity     // => 1
  ```
  */
  parity -> int:
    return population-count & 1

  /**
  Counts the number of ones in the binary representation of the integer.
  Returns false if the number is odd, true if the number is even.
  The integer is treated as a 64 bit number.
    Thus it returns false if called on -1.

  # Examples
  ```
  (0b101101).parity  // => true
  (0b101100).parity  // => false
  (0b101110).parity  // => true
  (0b101111).parity  // => false
  (0).parity         // => true
  (-1).parity        // => true
  int.MIN.parity     // => false
  int.MAX.parity     // => false
  ```
  */
  has-even-parity -> bool:
    return (population-count & 1) == 0

  /**
  Counts the number of ones in the binary representation of the integer.
  Returns true if the number is odd, false if the number is even.
  The integer is treated as a 64 bit number.
    Thus it returns true if called on -1.

  # Examples
  ```
  (0b101101).parity  // => false
  (0b101100).parity  // => true
  (0b101110).parity  // => false
  (0b101111).parity  // => true
  (0).parity         // => false
  (-1).parity        // => false
  int.MIN.parity     // => true
  int.MAX.parity     // => true
  ```
  */
  has-odd-parity -> bool:
    return (population-count & 1) == 1

class SmallInteger_ extends int:
  /** See $super. */
  operator + other:
    #primitive.core.smi-add:
      return other.add-from-small-integer_ this

  /** See $super. */
  operator - other:
    #primitive.core.smi-subtract:
      return other.subtract-from-small-integer_ this

  /** See $super. */
  operator * other:
    #primitive.core.smi-multiply:
      return other.multiply-from-small-integer_ this

  /** See $super. */
  operator / other:
    #primitive.core.smi-divide:
      if it == "DIVISION_BY_ZERO": throw it
      return other.divide-from-small-integer_ this

  /** See $super. */
  operator % other:
    #primitive.core.smi-mod:
      if it == "DIVISION_BY_ZERO": throw it
      return other.mod-from-small-integer_ this

  /** See $super. */
  operator == other -> bool:
    #primitive.core.smi-equals:
      return other is num and other.equals-from-small-integer_ this

  /** See $super. */
  operator < other -> bool:
    #primitive.core.smi-less-than:
      return other.less-than-from-small-integer_ this

  /** See $super. */
  operator <= other -> bool:
    #primitive.core.smi-less-than-or-equal:
      return other.less-than-or-equal-from-small-integer_ this

  /** See $super. */
  operator > other -> bool:
    #primitive.core.smi-greater-than:
      return other.greater-than-from-small-integer_ this

  /** See $super. */
  operator >= other -> bool:
    #primitive.core.smi-greater-than-or-equal:
      return other.greater-than-or-equal-from-small-integer_ this

  /** See $super. */
  operator - -> int:
    #primitive.core.smi-unary-minus

  /** See $super. */
  operator ~ -> int:
    #primitive.core.smi-not

  /** See $super. */
  operator & other -> int:
    #primitive.core.smi-and:
      return other.and-from-small-integer_ this

  /** See $super. */
  operator | other -> int:
    #primitive.core.smi-or:
      return other.or-from-small-integer_ this

  /** See $super. */
  operator ^ other -> int:
    #primitive.core.smi-xor:
      return other.xor-from-small-integer_ this

  /** See $super. */
  operator >> number-of-bits -> int:
    #primitive.core.smi-shift-right

  /** See $super. */
  operator >>> number-of-bits -> int:
    #primitive.core.smi-unsigned-shift-right

  /** See $super. */
  operator << number-of-bits -> int:
    #primitive.core.smi-shift-left

  /** See $super. */
  to-string -> string:
    #primitive.core.smi-to-string-base-10

  /** See $super. */
  repeat [block] -> none:
    #primitive.intrinsics.smi-repeat:
      // The intrinsic only fails if we cannot call the block with a single
      // argument. We force this to throw by doing the same here.
      block.call this

  // Double dispatch support for binary operations.

  add-from-float_ other:
    return other + to-float

  subtract-from-float_ other:
    return other - to-float

  multiply-from-float_ other:
    return other * to-float

  divide-from-float_ other:
    return other / to-float

  mod-from-float_ other:
    return other % to-float

  equals-from-float_ other:
    return other == to-float

  less-than-from-float_ other:
    return other < to-float

  less-than-or-equal-from-float_ other:
    return other <= to-float

  greater-than-from-float_ other:
    return other > to-float

  greater-than-or-equal-from-float_ other:
    return other >= to-float

class LargeInteger_ extends int:
  /** See $super. */
  operator + other:
    #primitive.core.large-integer-add:
      return other.add-from-large-integer_ this

  /** See $super. */
  operator - other:
    #primitive.core.large-integer-subtract:
      return other.subtract-from-large-integer_ this

  /** See $super. */
  operator * other:
    #primitive.core.large-integer-multiply:
      return other.multiply-from-large-integer_ this

  /** See $super. */
  operator / other:
    #primitive.core.large-integer-divide:
      if it == "DIVISION_BY_ZERO": throw it
      return other.divide-from-large-integer_ this

  /** See $super. */
  operator % other:
    #primitive.core.large-integer-mod:
      if it == "DIVISION_BY_ZERO": throw it
      return other.mod-from-large-integer_ this

  /** See $super. */
  operator == other -> bool:
    #primitive.core.large-integer-equals:
      return other is num and other.equals-from-large-integer_ this

  /** See $super. */
  operator < other -> bool:
    #primitive.core.large-integer-less-than:
      return other.less-than-from-large-integer_ this

  /** See $super. */
  operator <= other -> bool:
    #primitive.core.large-integer-less-than-or-equal:
      return other.less-than-or-equal-from-large-integer_ this

  /** See $super. */
  operator > other -> bool:
    #primitive.core.large-integer-greater-than:
      return other.greater-than-from-large-integer_ this

  /** See $super. */
  operator >= other -> bool:
    #primitive.core.large-integer-greater-than-or-equal:
      return other.greater-than-or-equal-from-large-integer_ this

  /** See $super. */
  operator - -> int:
    #primitive.core.large-integer-unary-minus

  /** See $super. */
  operator ~ -> int:
    #primitive.core.large-integer-not

  /** See $super. */
  operator & other -> int:
    #primitive.core.large-integer-and:
      return other.and-from-large-integer_ this

  /** See $super. */
  operator | other -> int:
    #primitive.core.large-integer-or:
      return other.or-from-large-integer_ this

  /** See $super. */
  operator ^ other -> int:
    #primitive.core.large-integer-xor:
      return other.xor-from-large-integer_ this

  /** See $super. */
  operator >> number-of-bits -> int:
    #primitive.core.large-integer-shift-right

  /** See $super. */
  operator >>> number-of-bits -> int:
    #primitive.core.large-integer-unsigned-shift-right

  /** See $super. */
  operator << number-of-bits -> int:
    #primitive.core.large-integer-shift-left

  /** See $super. */
  to-string -> string:
    return to-string --radix=10

  /** See $super */
  to-int -> int: return this

  add-from-float_ other:
    return other + to-float

  subtract-from-float_ other:
    return other - to-float

  multiply-from-float_ other:
    return other * to-float

  divide-from-float_ other:
    return other / to-float

  mod-from-float_ other:
    return other % to-float

  equals-from-float_ other:
    return other == to-float

  less-than-from-float_ other:
    return other < to-float

  less-than-or-equal-from-float_ other:
    return other <= to-float

  greater-than-from-float_ other:
    return other > to-float

  greater-than-or-equal-from-float_ other:
    return other >= to-float

/**
A 64 bit floating point value.
Floats are double precision IEEE 754 values, including $float.NAN,
  $float.INFINITY, -$float.INFINITY and negative zero.
This is a fully fledged class, not a 'primitive type'.
Floats are immutable objects.
See also https://docs.toit.io/language/math.
*/
class float extends num:

  /**
  A not-a-number representation.

  Use $is-nan to check for not-a-number.

  # Advanced
  There are multiple representations of not-a-number. For example, the
  following produces another not-a-number representation:
  ```
  float.from-bits (float.NAN.bits + 1)
  ```
  Comparing the above representation with this constant will result in false:
  ```
  float.NAN == float.from-bits (float.NAN.bits + 1)  // => false
  ```
  It is therefore important to use $is-nan to check for not-a-number.
  */
  static NAN          /float ::= 0.0 / 0.0
  /**
  The infinity representation.
  */
  static INFINITY     /float ::= 1.0 / 0.0
  /**
  The maximum finite float.
  */
  static MAX-FINITE   /float ::= 0x1F_FFFF_FFFF_FFFFp971
  /**
  The minimum positive float.
  */
  static MIN-POSITIVE /float ::= 0x1p-1074

/**
  Parses the $data to a float.

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
  static parse data/io.Data -> float:
    return parse_ data 0 data.byte-size --if-error=: throw it

  /** Deprecated. Use $(parse data [--if-error]) instead. */
  static parse data/io.Data [--on-error] -> float?:
    return parse data --if-error=on-error

  /**
  Variant of $(parse data).

  If the data can't be parsed correctly, returns the result of calling the $if-error block.
  */
  static parse data/io.Data [--if-error] -> float?:
    return parse_ data 0 data.byte-size --if-error=if-error

  /**
  Deprecated. Use $(parse data) with slices instead.
  */
  static parse data/io.Data from/int to/int=data.byte-size -> float:
    return parse_ data from to --if-error=: throw it

  static parse_ data/io.Data from/int to/int [--if-error] -> float?:
    #primitive.core.float-parse:
      if it == "WRONG_BYTES_TYPE": return parse_ (ByteArray.from data) from to --if-error=if-error
      if it == "ERROR": return if-error.call "FLOAT_PARSING_ERROR"
      return if-error.call it

  /**
  Returns the sign of this instance.

  The sign is:
  - -1 for negative numbers, and for -0.0
  - 0 for 0.0
  - 1 for positive numbers.
  */
  sign -> int:
    #primitive.core.float-sign

  /** See $super. */
  operator - -> float:
    #primitive.core.float-unary-minus

  /** See $super. */
  operator + other -> float:
    #primitive.core.float-add:
      return other.add-from-float_ this

  /** See $super. */
  operator - other -> float:
    #primitive.core.float-subtract:
      return other.subtract-from-float_ this

  /** See $super. */
  operator * other -> float:
    #primitive.core.float-multiply:
      return other.multiply-from-float_ this

  /** See $super. */
  operator / other -> float:
    #primitive.core.float-divide:
      return other.divide-from-float_ this

  /** See $super. */
  operator % other -> float:
    #primitive.core.float-mod:
      return other.mod-from-float_ this

  /** See $super. */
  operator == other -> bool:
    #primitive.core.float-equals:
      return other is num and other.equals-from-float_ this

  /** See $super. */
  operator < other -> bool:
    #primitive.core.float-less-than:
      return other.less-than-from-float_ this

  /** See $super. */
  operator <= other -> bool:
    #primitive.core.float-less-than-or-equal:
      return other.less-than-or-equal-from-float_ this

  /** See $super. */
  operator > other -> bool:
    #primitive.core.float-greater-than:
      return other.greater-than-from-float_ this

  /** See $super. */
  operator >= other -> bool:
    #primitive.core.float-greater-than-or-equal:
      return other.greater-than-or-equal-from-float_ this

  /** See $super. */
  abs -> float:
    return sign == -1 ? -this : this

  /** See $super. */
  sqrt -> float:
    #primitive.core.float-sqrt

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
    rounded-float := round_ --precision=0
    return rounded-float.to-int

  round_ --precision -> float:
    #primitive.core.float-round

  /** Deprecated. */
  round --precision -> float:
    return round_ --precision=precision

  /**
  Returns the smallest integral value not less than this number.

  If this value is not finite (NaN, infinity, or negative infinity), then returns this number.
  */
  ceil -> float:
    #primitive.core.float-ceil

  /**
  Returns the largest integer not greater than this number.

  If this value is not finite (NaN, infinity, or negative infinity), then returns this number.
  */
  floor -> float:
    #primitive.core.float-floor

  /**
  Rounds this to the nearest value that is not larger in magnitude than this number.

  If this value is not finite (NaN, infinity, or negative infinity), then returns this number.
  */
  truncate -> float:
    #primitive.core.float-trunc

  /**
  See $super.

  If $precision is null, the shortest correct string is returned.
  If $precision is an integer format "%.*lf" in C++ is used.

  # Errors
  The $precision must be an integer in range [0..64] or null.
  */
  to-string --precision/int?=null -> string:
    if precision and not 0 <= precision <= 64:
      throw "OUT_OF_RANGE"
    #primitive.core.float-to-string

  /** Deprecated. Use $(to-string --precision) instead. */
  stringify precision -> string:
    #primitive.core.float-to-string

  /**
  Whether this number is a NaN ($float.NAN).

  # Examples
  ```
  float.NAN.is-nan                               // => true
  (-1).sqrt.is-nan                               // => true
  (float.from-bits (float.NAN.bits + 1)).is-nan  // => true

  2.0.is-nan                 // => false
  2.sqrt.is-nan              // => false
  float.INFINITY.is-nan      // => false
  float.MAX-FINITE.is-nan    // => false
  float.MIN_POSITIVE.is-nan  // => false
  ```
  */
  is-nan -> bool:
    #primitive.core.float-is-nan

  /**
  Whether this number is finite.

  # Examples
  ```
  2.0.is-finite                 // => true
  (-9001.0).is-finite           // => true
  2.sqrt.is-finite              // => true
  float.MAX-FINITE.is-finite    // => true
  float.MIN_POSITIVE.is-finite  // => true

  float.NAN.is-finite       // => false
  (-1).sqrt.is-finite       // => false
  float.INFINITY.is-finite  // => false
  ```
  */
  is-finite -> bool:
    #primitive.core.float-is-finite

  /** See $super. */
  to-int -> int:
    #primitive.core.number-to-integer

  /**
  Converts this number to its bit representation.

  A $float corresponds to the IEEE 754 double precision (binary64) type. It has
    64 bits, of which 1 bit is used as sign, 11 for the exponent, and 52 for the
    significant.

  This function is the inverse of $from-bits.
  */
  bits -> int:
    #primitive.core.float-to-raw

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
    #primitive.core.float-to-raw32

  /**
  Converts to $raw bit pattern to the corresponding $float.

  This function is the inverse of $bits.
  */
  static from-bits raw/int -> float:
    #primitive.core.raw-to-float

  /**
  Converts the given $raw bits to a 32-bit floating-point number and
    returns the corresponding $float.

  Given the $raw bits of an IEEE 754 single-precision (binary32)
    floating-point number, constructs the corresponding value, and
    returns it as a $float.

  This function is the inverse of $bits32.
  */
  static from-bits32 raw/int -> float:
    #primitive.core.raw32-to-float

  // Double dispatch support for binary operations.

  add-from-small-integer_ other:
    return other.to-float + this

  subtract-from-small-integer_ other:
    return other.to-float - this

  multiply-from-small-integer_ other:
    return other.to-float * this

  divide-from-small-integer_ other:
    return other.to-float / this

  mod-from-small-integer_ other:
    return other.to-float % this

  equals-from-small-integer_ other:
    return other.to-float == this

  less-than-from-small-integer_ other:
    return other.to-float < this

  less-than-or-equal-from-small-integer_ other:
    return other.to-float <= this

  greater-than-from-small-integer_ other:
    return other.to-float > this

  greater-than-or-equal-from-small-integer_ other:
    return other.to-float >= this

  add-from-large-integer_ other:
    return other.to-float + this

  subtract-from-large-integer_ other:
    return other.to-float - this

  multiply-from-large-integer_ other:
    return other.to-float * this

  divide-from-large-integer_ other:
    return other.to-float / this

  mod-from-large-integer_ other:
    return other.to-float % this

  // For int/float comparisons we should never get to these routines because
  // the byte code takes care of it, even getting the tricky cases right where
  // the int is too large to convert exactly to a float without rounding.  That
  // tricky case is not replicated here, so we want to ensure we never get
  // here.

  equals-from-large-integer_ other:
    if other is int: unreachable  // See comment above.
    return other.to-float == this

  less-than-from-large-integer_ other:
    if other is int: unreachable  // See comment above.
    return other.to-float < this

  less-than-or-equal-from-large-integer_ other:
    if other is int: unreachable  // See comment above.
    return other.to-float <= this

  greater-than-from-large-integer_ other:
    if other is int: unreachable  // See comment above.
    return other.to-float > this

  greater-than-or-equal-from-large-integer_ other:
    if other is int: unreachable  // See comment above.
    return other.to-float >= this
