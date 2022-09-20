// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bitmap

// Returns the number of bytes needed to code the char in UTF-8.
utf_8_bytes char:
  return write_utf_8_to_byte_array null 0 char

// Writes 1-4 bytes to the byte array, corresponding to the UTF-8 encoding of
// Unicode code point given as 'char'.  Returns the number of bytes written.
write_utf_8_to_byte_array byte_array position char:
  if char < 0: throw "INVALID_ARGUMENT"
  if char <= 0x7f:
    if byte_array: byte_array[position] = char
    return 1
  if char >= 0xd800 and not 0xe000 <= char <= 0x10ffff: throw "INVALID_ARGUMENT"
  bytes := 2
  mask := 0x1f
  shifted := 6
  while char >> shifted > mask:
    bytes++
    mask >>= 1
    shifted += 6
  if byte_array:
    unary_bits := (0xff00 >> bytes) & 0xff
    byte_array[position++] = (char >> shifted) | unary_bits
    while shifted > 0:
      shifted -= 6
      byte_array[position++] = 0x80 | ((char >> shifted) & 0x3f)
  return bytes

is_unicode_whitespace_ c/int -> bool:
  // This list should be kept in sync with the comment in $string.trim.
  // Whitespace ranges are: 0x0009-0x000D
  //                        0x0020, 0x0085, 0x00A0 0x1680
  //                        0x2000-0x200A, 0x2028, 0x2029, 0x202F, 0x205F
  //                        0x3000, 0xFEFF.
  if c < 0x85:
    if 0x0009 <= c <= 0x000D: return true
    if c == 0x0020: return true
  else if c < 0x2000:
    if c == 0x0085 or c == 0x00A0 or c == 0x1680: return true
  else if c < 0x3000:
    if c <= 0x200A or c == 0x2028 or c == 0x2029 or c == 0x202F or c == 0x205F: return true
  else if c == 0x3000 or c == 0xFEFF:
    return true
  return false

abstract class string implements Comparable:
  static MIN_SLICE_SIZE_ ::= 16

  /**
  Constructs a single-character string from one Unicode code point.
  If $rune is greater than 0x7f, the result string will have
    size > 1 and contain more than one UTF-8 byte .

  # Examples
  ```
  str1 := string.from_rune 'a'  // -> "a"
  str2 := string.from_rune 0x41 // -> "A"
  str3 := string.from_rune 42   // -> "*"
  str4 := string.from_rune 7931 // -> "☃"
  ```
  */
  constructor.from_rune rune/int:
    #primitive.core.string_from_rune

  /**
  Constructs a string from a list of Unicode code points.
  All elements of the list must be in the Unicode range of 0 to 0x10ffff, inclusive.
  Since UTF-8 encoding is used, if any elements of the list are greater than
    the maximum ASCII value of 0x7f the size of the string will be greater than
    the size of the list.
  UTF-8 bytes are not valid input to this constructor.  If you have a ByteArray
    of UTF-8 bytes, use the $ByteArray.to_string method instead.

  # Examples
  ```
  str1 := string.from_runes ['a', 'b', 42]  // -> "ab*"
  str2 := string.from_runes [0x41]          // -> "A"
  str3 := string.from_runes [42]            // -> "*"
  str4 := string.from_runes [7931, 0x20ac]  // -> "☃€"
  ```
  */
  constructor.from_runes runes/List:
    length := 0
    runes.do:
      length += utf_8_bytes it
    ba := ByteArray length
    length = 0
    runes.do:
      length += write_utf_8_to_byte_array ba length it
    return ba.to_string

  constructor.from_subclass_:

  /**
  The size of this instance in UTF-8 code units (byte-sized).

  The string may have fewer runes (Unicode "code points") than its size.
  For example the string "Amélie" has a size of 7, but a `size --runes` of 6.
  */
  size -> int:
    #primitive.core.string_length

  /** Whether this instance is the empty string `""`. */
  is_empty -> bool:
    return size == 0

  /**
  Returns the number of runes (Unicode "code points") in this string.

  This operation takes linear time to complete as it runs through the whole string.

  The flag $runes must be true.
  */
  size --runes/bool -> int:
    if runes != true: throw "Bad Argument"
    return rune_size_

  rune_size_ -> int:
    #primitive.core.string_rune_count

  /**
  The rune (Unicode "code point") at position $i of the underlying bytes.

  Returns null if $i points into the middle of a multi-byte sequence.

  It is an error if $i is not in range 0 (inclusive) to $size (exclusive).
  # Examples
  ```
  str := "Amélie"
  print "$(%c str[2])" // => é
  print str[3]         // => null
  print "$(%c str[4])" // => l
  ```
  */
  abstract operator [] i/int -> int?

  /**
  Returns a slice of this string.

  Slices are views on the underlying object. Contrary to $copy, they don't
    (always) create a new string, but rather point into the original string.
  String slices behave exactly the same as normal strings.

  The parameter $from is inclusive.
  The parameter $to is exclusive.

  # Advanced
  Slices keep the whole string alive. This can lead to memory
    waste if the string is not used otherwise. In some cases it
    might thus make sense to call $copy on the slice.

  At the call-site the arguments $from and $to are passed in with the slice
    syntax: `str[from..to]`. Since both arguments are optional (as they have
    default values), it is valid to omit `from` or `to`.

  # Examples
  ```
  str := "hello world"
  hello := str[..5]
  world := str[6..]
  print hello  // => "hello"
  print world  // => "world"
  ```
  */
  // TODO(florian): make this an overloaded function. Currently we can't because
  // of abstract method restrictions.
  operator [..] --from=0 --to=size -> string:
    if not 0 <= from <= to <= size: throw "OUT_OF_BOUNDS"
    if from == 0 and to == size: return this
    if to - from < MIN_SLICE_SIZE_: return copy from to
    if this is String_: return StringSlice_ (this as String_) from to
    slice := this as StringSlice_
    return StringSlice_ slice.str_ (slice.from_ + from) (slice.from_ + to)

  /**
  The raw byte (Unicode codeunit) at position $i in the UTF-8 byte representation
    of this string.

  Contrary to $at this method never returns null.

  The flag $raw must be true
  */
  at --raw/bool i/int -> int:
    if raw != true: throw "Bad Argument"
    return raw_at_ i

  /**
  Iterates over all slots in the string (as if using $at) and calls the given $block with
    the values.

  For every multi-byte sequences in the string, the $block is invoked first with the
    rune (Unicode "code point"), then with null for each remaining codeunit of the sequence.

  This function is equivalent to:
  ```
  size.repeat: block.call this[it]
  ```

  # Examples
  ```
  "é".do: print it // 233, null
  ```
  */
  do [block] -> none:
    for i := 0; i < size; i++: block.call this[i]

  /**
  Iterates over all runes (Unicode "code point") and calls the given $block with the values.

  Contrary to $do, only invokes $block with valid integer values. For every multi-byte sequences
    there is only one call to $block.

  The flag $runes must be true.

  # Examples
  ```
  "Amélie".do --runes: print "$(%c it)" // A, m, é, l, i, e
  ```
  */
  do --runes/bool [block] -> none:
    if runes != true: throw "Bad Argument"
    for i := 0; i < size; i++:
      rune := this[i]
      if rune: block.call rune

  /**
  Copies the string between $from (inclusive) and $size (exclusive).

  The given substring must be legal. That is, $from must not point into
    the middle of a multi-byte sequence.
  */
  copy from/int=0 -> string: return copy from size

  /**
  Copies the string between $from (inclusive) and $to (exclusive).

  The given substring must be legal. That is, neither $from nor $to can point into
    the middle of a multi-byte sequence.
  */
  abstract copy from/int to/int -> string

  /**
  Copies the string between $from (inclusive) and $to (exclusive).

  If $force_valid is true, adjusts $from and $to so that they are valid substring indexes.
    If $from (resp. $to) points to the middle of a multi-byte sequence decreases the index
    until it points to the beginning of the sequence. Also see $rune_index.
  */
  copy from/int to/int=size --force_valid/bool -> string:
    if force_valid:
      from = rune_index from
      to = rune_index to
    return copy from to

  /** Equivalent to $copy, but can be used when you have either a ByteArray or a string. */
  to_string from=0 to=size -> string:
    return copy from to

  /**
  Returns the index of the rune pointed to by $index.

  Returns $index if it is equal to the size.
  Returns $index if it points to the beginning of a rune.
  Otherwise decreases $index until it points to the beginning of the multi-byte sequence.

  The parameter $index must satisfy: `0 <= index <= size`.
  */
  rune_index index/int -> int:
    if index == size: return index
    // TODO(florian): make this more efficient?
    while this[index] == null: index--
    return index

  safe_at_ index/int -> int:
    return index >= size ? -1 : this[index]


  /**
  Formats the $object according to the given $format.

  The normal way of using this functionality is through the
    string interpolation syntax - see
    https://docs.toit.io/language/strings/#string-interpolation

  The $format description is very similar to `printf`.

  Extensions relative to printf:
  - `^` for centering.

  Missing relative to printf: No support for `%g` or `%p`.

  Like in printf the hexadecimal and octal format specifiers,
    %x and %o will treat all values as unsigned.  See also
    $int.stringify.

  Format Description:
  ```
  [alignment][precision][type]
  alignment = flags<digits>
  flags = '-' | '^' | '>'   (> is default, can't be used in the syntax)
  precision = .<digits>
  type 'd' | 'f' | 's' | 'o' | 'x' | 'c'
  ```
  */
  static format format/string object -> string:
    pos := 0
    char := format.safe_at_ pos++
    alignment_type := '>'
    precision := null
    type := 's'
    // Read optional alignment.
    if char == '^' or char == '-':
      alignment_type = char
      char = format.safe_at_ pos++
    // Read optional field width.
    start := pos - 1
    zero_pad := char == '0'
    if zero_pad and alignment_type != '>': throw "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT $format"
    while '0' <= char <= '9': char = format.safe_at_ pos++
    alignment_width := start == pos - 1
        ? 0
        : int.parse_ format start (pos - 1) --radix=10 --on_error=: throw it
    if char == '.':
      start = pos
      char = format.safe_at_ pos++
      while '0' <= char <= '9': char = format.safe_at_ pos++
      if start == pos - 1: throw "MISSING_PRECISION_IN_FORMAT $format"
      precision = int.parse format[start..pos - 1]
    if char == -1: throw "MISSING_TYPE_IN_FORMAT $format"
    type = char
    char = format.safe_at_ pos++
    if char != -1: throw "UNEXPECTED_TRAILING_CHARACTERS_IN_FORMAT $format"
    meat := ""
    meat_size := null
    if type == 's':
      meat = object.stringify
      meat_size = meat.size --runes
    else if type == 'f':
      d := object.to_float
      meat = precision ? (d.stringify precision) : d.stringify
    else if type == 'd': meat = object.to_int.stringify
    else if type == 'o': meat = printf_style_int_stringify_ object.to_int 8
    else if type == 'x': meat = printf_style_int_stringify_ object.to_int 16
    else if type == 'X':
      meat = printf_style_int_stringify_ object.to_int 16
      meat = (ByteArray meat.size: meat[it] >= 'a' ? meat[it] + 'A' - 'a' : meat[it]).to_string
    else if type == 'c':
      character := object.to_int
      ba := ByteArray (utf_8_bytes character)
      write_utf_8_to_byte_array ba 0 character
      meat = ba.to_string
      meat_size = 1
    else: throw "WRONG_TYPE_IN_FORMAT $format"
    if not meat_size: meat_size = meat.size
    if alignment_width < meat_size: return meat
    padding := alignment_width - meat_size
    if alignment_type == '-': return meat.pad_ 0 padding ' '
    if alignment_type == '>': return meat.pad_ padding 0 (zero_pad ? '0' : ' ')
    assert: alignment_type == '^'
    return meat.pad_ (padding / 2) (padding - padding / 2) ' '

  /**
  The hash code for this instance.

  This operation is in `O(1)`.
  */
  abstract hash_code

  raw_at_ n:
    #primitive.core.string_raw_at

  /**
  Concatenates this instance with the given $other string.
  */
  operator + other/string -> string:
    #primitive.core.string_add

  /**
  Concatenates $amount copies of this instance.

  The parameter $amount must be >= 0.
  */
  operator * amount/int -> string:
    if amount < 0: throw "Bad Argument"
    if amount == 0 or size == 0: return ""
    if amount == 1: return this
    new_size := size * amount
    array := ByteArray new_size
    bitmap.blit this array size --source_line_stride=0
    return array.to_string

  /** See $super. */
  operator == other:
    if other is not string: return false
    #primitive.core.blob_equals


  /**
  Whether this instance is less than $other.

  Uses $compare_to to determine the ordering of the two strings.
  */
  operator < other/string -> bool:
    return (compare_to other) == -1

  /**
  Whether this instance is less or equal to $other.

  Uses $compare_to to determine the ordering of the two strings.
  */
  operator <= other/string -> bool:
    return (compare_to other) != 1

  /**
  Whether this instance is greater than $other.

  Uses $compare_to to determine the ordering of the two strings.
  */
  operator > other/string -> bool:
    return (compare_to other) == 1

  /**
  Whether this instance is greater or equal to $other.

  Uses $compare_to to determine the ordering of the two strings.
  */
  operator >= other/string -> bool:
    return (compare_to other) != -1

  /**
  Compares the two given strings.

  Returns 1 if this instance is greater than $other.
  Returns 0 if this instance is equal to $other.
  Returns -1 if this instance is less than $other.

  The comparison is done based on Unicode values. That is, string A is considered
    less than string B, if a leading prefix (potentially empty) is the same, and
    string A has a Unicode value (rune/code unit) less than string B at the following
    position.
  If string A is a prefix of string B, then A is less than B.

  # Errors
  Since natural languages often have different requirements for sorting, it is
    not sufficient to use this method for natural language sorting (also known as
    "collation").
  For example, this method considers "Amélie" as greater than "Amzlie". In French,
    accented characters should be ordered similar to non-accented characters. This
    ordering would thus be wrong.
  Similarly, in Spanish, words containing "ñ" would not be sorted correctly. The
    "ñ" is collated between "n" and "o" (contrary to Unicode's position after all
    ASCII characters).

  # Examples
  ```
  "a".compare_to "b"    // => -1
  "a".compare_to "a"    // => 0
  "b".compare_to "a"    // => 1
  "ab".compare_to "abc" // => -1
  "abc".compare_to "ab" // => 1
  "Amélie".compare_to "Amelie"  // => 1
  "Amélie".compare_to "Amzlie"  // => 1
  ```
  */
  compare_to other/string -> int:
    #primitive.core.string_compare

  /**
  Compares this instance with $other and calls $if_equal if the two are equal.

  See $compare_to for documentation on the ordering.

  The $if_equal block is called only if this instance and $other are equal.
  The $if_equal block should return -1, 0, or 1 (since it becomes the result of
    the call to this method).

  # Examples
  The $if_equal block allows easy chaining of `compare_to` calls.
  ```
  // In class A with fields str_field1 and str_field2:
  compare_to other/A -> int:
    return str_field1.compare_to other.str_field1 --if_equal=:
      str_field2.compare_to other.str_field2
  ```
  */
  compare_to other/string [--if_equal] -> int:
    result := compare_to other
    if result == 0: return if_equal.call
    return result

  stringify:
    return this

  /**
  Pads this instance with char on the left, until the total size of the string is $amount.

  Returns this instance directly if this instance is longer than $amount.

  The flag $left must be true.

  # Examples
  ```
  str := "foo"
  str.pad --left 5     // => "  foo"
  str.pad --left 5 '0' // => "00foo"

  str.pad --left 3     // => "foo"
  str.pad --left 1     // => "foo"

  str.pad 5     // => "  foo"
  str.pad 5 '0' // => "00foo"

  str.pad 3     // => "foo"
  str.pad 1     // => "foo"
  ```
  */
  pad --left/bool=true amount/int char/int=' ' -> string:
    if left != true: throw "Bad Argument"
    return pad_ (amount - size) 0 char

  /**
  Pads this instance with $char on the right, until the total size of the string is $amount.

  Returns this instance directly if this instance is longer than $amount.

  The flag $right must be true.

  # Examples
  ```
  str := "foo"
  str.pad --right 5     // => "foo  "
  str.pad --right 5 '0' // => "foo00"

  str.pad --right 3     // => "foo"
  str.pad --right 1     // => "foo"
  ```
  */
  pad --right/bool  amount/int char/int=' ' -> string:
    if right != true: throw "Bad Argument"
    return pad_ 0 (amount - size) char

  /**
  Pads this instance with $char on the left and right, until the total size of the string is $amount.

  Returns a string where this instance is centered. If the padding can't be divided evenly, adds more
    padding to the right.

  Returns this instance directly if this instance is longer than $amount.

  The flag $center must be true.

  # Examples
  ```
  str := "foo"
  str.pad --center 5     // => " foo "
  str.pad --center 5 '0' // => "0foo0"

  str.pad --center 6     // => " foo  "
  str.pad --center 6 '0' // => "0foo00"

  str.pad --center 3     // => "foo"
  str.pad --center 1     // => "foo"
  ```
  */
  pad --center/bool amount/int char/int=' ' -> string:
    if center != true: throw "Bad Argument"
    padding := amount - size
    left := padding / 2
    right := padding - left
    return pad_ left right char

  pad_ left right char -> string:
    if left < 0 or right < 0: return this
    width := utf_8_bytes char
    array := ByteArray (left + right) * width + size
    pos := 0;
    left.repeat: pos += write_utf_8_to_byte_array array pos char
    write_to_byte_array_ array 0 size pos
    pos += size
    right.repeat: pos += write_utf_8_to_byte_array array pos char
    return array.to_string

  /**
  Whether this instance starts with the given $prefix.
  */
  starts_with prefix/string -> bool:
    return matches prefix --at=0

  /**
  Whether this instance ends with the given $suffix.
  */
  ends_with suffix/string -> bool:
    return matches suffix --at=(size - suffix.size)

  /**
  Whether this instance has an occurrence of $needle at index $at.

  The index $at does not need to be valid.

  # Examples
  ```
  "Toad the Wet Sprocket".matches "Toad"     --at=0   // => true
  "Toad the Wet Sprocket".matches "Toad"     --at=-1  // => false
  "Toad the Wet Sprocket".matches "Sprocket" --at=13  // => true
  ```
  */
  matches needle/string --at/int -> bool:
    if at < 0: return false
    if at + needle.size > size: return false
    needle.size.repeat:
      if this[at + it] != needle[it]: return false
    return true

  /**
  Whether this instance matches a simplified glob $pattern.
  Two characters are used for wildcard matching:
    '?' will match any single Unicode character.
    '*' will match any number of Unicode characters.

  The private optional named argument $position_ is used for recursive calls.

  # Examples
  ```
  "Toad".glob "Toad"   // => true
  "Toad".glob "To?d"   // => true
  "Toad".glob "To"     // => false
  "To*d".glob "To\\*d" // => true
  "Toad".glob "To\\*d" // => false
  ```
  */

  glob pattern/string --position_/int=0 -> bool:
    pattern_pos := 0
    while pattern_pos < pattern.size or position_ < size:
      if pattern_pos < pattern.size:
        pattern_char := pattern[pattern_pos]
        if pattern_char == '?':
          if position_ < size:
            pattern_pos += utf_8_bytes pattern_char
            position_ += utf_8_bytes this[position_]
            continue
        else if pattern_char == '*':
          sub_pattern := pattern.copy pattern_pos + 1
          while position_ <= size:
            if glob sub_pattern --position_=position_: return true
            position_ += position_ == size ? 1 : utf_8_bytes this[position_]
        else if position_ < size and ((pattern_char == '\\') or (this[position_] == pattern_char)):
          if pattern_char == '\\':
            if pattern_pos >= pattern.size: return false
            pattern_pos++
            if this[position_] != pattern[pattern_pos]: return false
          pattern_pos += utf_8_bytes pattern_char
          position_ += utf_8_bytes this[position_]
          continue
      return false
    return true

  /**
  Searches for $needle in the range $from (inclusive) - $to (exclusive).

  If $last is false (the default) returns the first occurrence of $needle in
    the given range $from - $to.

  If $last is true returns the last occurrence of $needle in the given range $from - $to, by
    searching backward. The $needle must be entirely contained within the range.

  The optional parameters $from and $to delimit the range in which
    the $needle is searched in. The $needle must be fully contained in
    the range $from..$to (as if taking a $copy with these parameters) to find the $needle.

  The range $from - $to must be valid and satisfy 0 <= $from <= $to <= $size.

  Returns -1 if $needle is not found.

  # Examples
  ```
  "foobar".index_of "foo"  // => 0
  "foobar".index_of "bar"  // => 3
  "foo".index_of "bar"     // => -1

  "foobarfoo".index_of "foo"           // => 0
  "foobarfoo".index_of "foo" 1         // => 6
  "foobarfoo".index_of "foo" 1 8       // => -1

  // Invalid ranges:
  "foobarfoo".index_of "foo" -1 999    // Throws.
  "foobarfoo".index_of "foo" 1 999     // Throws.

  "".index_of "" 0 0   // => 0
  "".index_of "" -3 -3 // => Throws
  "".index_of "" 2 2   // => Throws

  // Last:
  "foobarfoo".index_of --last "foo"           // => 6
  "foobarfoo".index_of --last "foo" 1         // => 6
  "foobarfoo".index_of --last "foo" 1 6       // => 0
  "foobarfoo".index_of --last "foo" 0 1       // => 0
  "foobarfoo".index_of --last "foo" 0 8       // => 0

  "foobarfoo".index_of --last "gee"           // => -1
  "foobarfoo".index_of --last "foo" 1 5       // => -1
  "foobarfoo".index_of --last "foo" 0 8       // => 0
  ```
  */
  index_of --last/bool=false needle/string from/int=0 to/int=size -> int:
    return index_of --last=last needle from to --if_absent=: -1

  /**
  Searches for $needle in the range $from (inclusive) - $to (exclusive).

  If $last is false (the default) returns the first occurrence of $needle in
    the given range $from - $to.

  If $last is true returns the last occurrence of $needle in the given range $from - $to, by
    searching backward.

  The optional parameters $from and $to delimit the range in which
    the $needle is searched in. The $needle must be fully contained in
    the range $from..$to (as if taking a $copy with these parameters) to find the $needle.

  The range $from - $to must be valid and satisfy 0 <= $from <= $to <= $size.

  Calls $if_absent with this instance if $needle is not found, and returns the result of that call.

  # Examples
  Also see $index_of for more examples.
  ```
  "foo".index_of "bar" --if_absent=: it.size            // => 3 (the size of "foo")
  "foobarfoo".index_of "foo" 1 8 --if_absent=: 499      // => 499
  "".index_of "" -3 -3 --if_absent=: throw "not found"  // Error
  "".index_of "" 2 2   --if_absent=: -1                 // => -1
  "foobarfoo".index_of "foo" 1 8 --if_absent=: 42       // => 42
  ```
  */
  index_of --last/bool=false needle/string from/int=0 to/int=size [--if_absent]:
    if not 0 <= from <= to <= size: throw "BAD ARGUMENTS"
    limit := to - needle.size
    if not last:
      for i := from; i <= limit; i++:
        if matches needle --at=i: return i
    else:
      for i := limit; i >= from; i--:
        if matches needle --at=i: return i
    return if_absent.call this

  /**
  Removes leading and trailing whitespace.
  Returns the trimmed string.

  # Advanced
  Whitespace is defined by the Unicode White_Space property (version 6.2 or later). It
    furthermore includes the BOM character 0xFEFF.

  As of Unicode 6.3 these are:
  ```
    0009..000D    ; White_Space # Cc   <control-0009>..<control-000D>
    0020          ; White_Space # Zs   SPACE
    0085          ; White_Space # Cc   <control-0085>
    00A0          ; White_Space # Zs   NO-BREAK SPACE
    1680          ; White_Space # Zs   OGHAM SPACE MARK
    2000..200A    ; White_Space # Zs   EN QUAD..HAIR SPACE
    2028          ; White_Space # Zl   LINE SEPARATOR
    2029          ; White_Space # Zp   PARAGRAPH SEPARATOR
    202F          ; White_Space # Zs   NARROW NO-BREAK SPACE
    205F          ; White_Space # Zs   MEDIUM MATHEMATICAL SPACE
    3000          ; White_Space # Zs   IDEOGRAPHIC SPACE

    FEFF          ; BOM                ZERO WIDTH NO_BREAK SPACE
  ```
  */
  trim -> string:
    if this == "": return this
    start := 0
    for ; start < size; start++:
      c := this[start]
      if c == null: continue  // Multi-byte UTF-8 character.
      if not is_unicode_whitespace_ c: break
    end := size
    for ; end > start; end--:
      c := this[end - 1]
      if c == null: continue  // Multi-byte UTF-8 character.
      if not is_unicode_whitespace_ c: break
    // If the last non-whitespace character is a multi-byte UTF-8 character
    //   we have to include them. Move forward again to find all of them.
    while end < size and this[end] == null: end++
    return copy start end


  /**
  Removes leading whitespace.
  Variant of $(trim).
  */
  trim --left/bool -> string:
    if left != true: throw "Bad Argument"
    size.repeat:
      c := this[it]
      if c != null and not is_unicode_whitespace_ c:
        return it == 0 ? this : copy it
    return ""

  /**
  Removes trailing whitespace.
  Variant of $(trim).
  */
  trim --right/bool -> string:
    if right != true: throw "Bad Argument"
    size.repeat:
      c := this[size - 1 - it]
      if c != null and not is_unicode_whitespace_ c:
        // If the last non-whitespace character is a multi-byte UTF-8 character
        //   we have to include them. Move forward again to find all of them.
        end := size - it
        while end < size and this[end] == null: end++
        return end == size ? this : copy 0 end
    return ""

  /**
  Removes a leading $prefix (if present).

  Returns this instance verbatim, if it doesn't start with $prefix.

  # Examples
  ```
  "http://www.example.com".trim --left "http://" // => "www.example.com"
  str := "foobar"
  str.trim --left "foo"  // => "bar"
  str.trim --left "bar"  // => "foobar"
  str.trim --left "gee"  // => "foobar"
  ```
  */
  trim --left/bool prefix/string -> string:
    if left != true: throw "Bad Argument"
    return trim --left prefix --if_absent=: it

  /**
  Removes a leading $prefix.

  Calls $if_absent if this instance does not start with $prefix. The argument
    to the block is this instance.

  # Examples
  ```
  "https://www.example.com".trim --left "http://" --if_absent=: it.trim --left "https://"  // => "www.example.com"
  str := "foobar"
  str.trim --left "foo" --if_absent=: "not_used" // => "bar"
  str.trim --left ""    --if_absent=: "not_used" // => "foobar"
  str.trim --left "gee" --if_absent=: it         // => "foobar"   (the default behavior)
  str.trim --left "gee" --if_absent=: throw "missing prefix" // ERROR
  ```
  */
  trim --left/bool prefix/string [--if_absent] -> string:
    if left != true: throw "Bad Argument"
    if not starts_with prefix: return if_absent.call this
    return copy prefix.size

  /**
  Removes a trailing $suffix (if present).

  Returns this instance verbatim, if it doesn't end with $suffix.

  # Examples
  ```
  "hello.toit".trim --right ".toit"  // => "hello"
  str := "foobar"
  str.trim --right "bar"  // => "foo"
  str.trim --right "foo"  // => "foobar"
  str.trim --right "gee"  // => "foobar"
  ```
  */
  trim --right/bool suffix/string -> string:
    if right != true: throw "Bad Argument"
    return trim --right suffix --if_absent=: it

  /**
  Removes a trailing $suffix.

  Calls $if_absent if this instance does not end with $suffix. The argument
    to the block is this instance.

  # Examples
  ```
  str := "foobar"
  str.trim --right "bar" --if_absent=: "not_used" // => "bar"
  str.trim --right ""    --if_absent=: "not_used" // => "foobar"
  str.trim --right "gee" --if_absent=: it         // => "foobar"   (the default behavior)
  str.trim --right "gee" --if_absent=: throw "missing suffix" // ERROR
  ```
  */
  trim --right/bool suffix/string [--if_absent] -> string:
    if right != true: throw "Bad Argument"
    if not ends_with suffix: return if_absent.call this
    return copy 0 (size - suffix.size)

  static TO_UPPER_TABLE_ ::= #[
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
      0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      // Add two extra lines so it can be used for to_lower too.
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

  static TO_LOWER_TABLE_ ::= TO_UPPER_TABLE_[32..]

  /**
  Returns a string where all ASCII lower case characters have
    been replaced with their upper case equivalents.
  Non-ASCII characters are unchanged.
  */
  to_ascii_upper -> string:
    return case_helper_ TO_UPPER_TABLE_

  /**
  Returns a string where all ASCII upper case characters have
    been replaced with their lower case equivalents.
  Non-ASCII characters are unchanged.
  */
  to_ascii_lower -> string:
    return case_helper_ TO_LOWER_TABLE_

  case_helper_ table/ByteArray -> string:
    if size == 0: return this
    single_byte := #[0]
    // By using "OR" as an operation and a pixel stride of 0 we can condense
    // the search for characters with the wrong case into a single byte,
    // avoiding an allocation of a new byte array and string in the cases
    // where it is not needed.
    bitmap.blit this single_byte size
        --lookup_table=table
        --operation=bitmap.OR
        --destination_pixel_stride=0
    if single_byte[0] == 0: return this
    // Since characters with the wrong case were found we create a new string
    // using a temporary byte array.
    bytes := to_byte_array
    bitmap.blit bytes bytes bytes.size --lookup_table=table --operation=bitmap.XOR
    return bytes.to_string

  /**
  Returns true iff the string has no non-ASCII characters in it.
  The implementation is optimized, but it takes linear time in the size of the
    string.
  */
  contains_only_ascii -> bool:
    return size == (size --runes)

  /**
  Splits this instance at $separator.

  If $at_first is false (the default) splits at *every* occurrence of $separator.
  If $at_first is true, splits only at the first occurrence of $separator.

  Calls $process_part for each part. It this instance starts or ends with a $separator,
    then $process_part is invoked with the empty string first and last, respectively.

  Splits are never in the middle of a UTF-8 multi-byte sequence. This is
    normally a consequence of the seperator (as well as this instance) being
    well-formed UTF-8. However, it is explicitly enforced for the zero length
    separator (the empty string).

  As a special case the empty separator does not result in a zero length string as
    the first and last entries, even though the empty separator can be found at
    both ends.  However if $at_first is true and the separator is empty then the
    result is one character, followed by the rest of the string even if that is an
    empty string.

  # Examples
  ```
  "Toad the Wet Sprocket".split "e": print it  // prints "Toad th", " W", "t Sprock", and "t"
  " the dust ".split " ": print it             // prints "the", "dust", and ""
  "abc".split  "":    print it                 // prints "a", "b", and "c"
  "foo".split  "foo": print it                 // prints "" and ""
  "afoo".split "foo": print it                 // prints "a" and ""
  "foob".split "foo": print it                 // prints "" and "b"
  "".split "": print it                        // Doesn't print.

  gadsby := "If youth, throughout all history, had had a champion to stand up for it;"
  gadsby.split "e": print it // prints the contents of gadsby

  "Toad the Wet Sprocket".split --at_first "e": print it  // prints "Toad th", " Wet Sprocket"
  " the dust ".split            --at_first " ": print it  // prints "", "the dust "
  gadsby.split                  --at_first "e": print it  // prints the contents of gadsby

  "abc".split  --at_first "":    print it     // prints "a" and "bc"
  "foo".split  --at_first "foo": print it     // prints "" and ""
  "afoo".split --at_first "foo": print it     // prints "a" and ""
  "foob".split --at_first "foo": print it     // prints "" and "b"
  "".split     --at_first "":    print it     // This is an error.
  "a".split    --at_first "":    print it     // prints "a" and ""
  ```
  */
  split --at_first/bool=false separator/string [process_part] -> none:
    if separator.size == 0:
      if at_first:
        if size == 0: throw "INVALID_ARGUMENT"
        len := utf_8_bytes this[0]
        process_part.call this[..len]
        process_part.call this[len..]
        return
      split_everywhere_ process_part
      return
    subject := this
    pos := 0
    while pos <= size:
      new_pos := subject.index_of separator pos --if_absent=:
        // No match.
        process_part.call (subject.copy pos size)
        return
      process_part.call (subject.copy pos new_pos)
      pos = new_pos + separator.size
      if at_first:
        if pos <= size: process_part.call (subject.copy pos)
        return

  /**
  Splits this instance at $separator.

  Returns a list of the separated parts.

  If $at_first is false (the default) splits at *every* occurrence of $separator.
  If $at_first is true, splits only at the first occurrence of $separator.

  Splits are never in the middle of a UTF-8 multi-byte sequence. This is
    normally a consequence of the seperator (as well as this instance) being
    well-formed UTF-8. However, it is explicitly enforced for the zero length
    separator (the empty string).

  # Examples
  ```
  "Toad the Wet Sprocket".split "e"  // => ["Toad th", " W", "t Sprock", "t"]
  " the dust ".split " "             // => ["", "the", "dust", ""]
  "abc".split  ""                    // => ["", "a", "b", "c"]
  "foo".split  "foo"                 // => ["", ""]
  "afoo".split "foo"                 // => ["a", ""]
  "foob".split "foo"                 // => ["", "b"]
  "".split ""                        // => [""]

  gadsby := "If youth, throughout all history, had had a champion to stand up for it;"
  gadsby.split "e"   // => [gadsby]

  "Toad the Wet Sprocket".split --at_first "e"  // => ["Toad th", " Wet Sprocket"]
  " the dust ".split            --at_first " "  // => ["", "the dust "]
  gadsby.split                  --at_first "e"  // => [gadsby]

  "abc".split  --at_first ""      // => ["", "abc"]
  "foo".split  --at_first "foo"   // => ["", ""]
  "afoo".split --at_first "foo"   // => ["a", ""]
  "foob".split --at_first "foo"   // => ["", "b"]
  "".split     --at_first ""      // => [""]
  ```
  */
  split --at_first/bool=false separator/string -> List/*<string>*/ :
    res := []
    split --at_first=at_first separator:
      res.add it
    return res

  split_everywhere_ [process_part]:
    subject := this
    size.repeat:
      c := subject[it]
      if c: process_part.call (subject.copy it it + (utf_8_bytes c))

  /**
  Returns whether $needle is present in this instance.

  The optional parameters $from and $to delimit the range in which
    the $needle is searched in. The $needle must be fully contained in
    the range $from..$to (as if taking a $copy with these parameters) to
    return true.

  The range $from - $to must be valid and satisfy 0 <= $from <= $to <= $size.
  */
  contains needle/string from/int=0 to/int=size -> bool:
    return (index_of needle from to) >= 0

  /**
  Replaces the given $needle with the $replacement string.

  If $all is true, replaces all occurrences of $needle. Otherwise, only replaces the first occurrence.

  Does nothing, if this instance doesn't contain the $needle.

  This operation only replaces occurrences of $needle that are fully contained in $from-$to.
  */
  replace --all/bool=false needle/string replacement/string from/int=0 to/int=size -> string:
    return replace --all=all needle from to: replacement

  /**
  Replaces the given $needle with the result of calling $replacement_callback.

  If $all is true, replaces all occurrences of $needle. For each found occurrence calls the
    $replacement_callback with the matched string as argument.

  If $all is false, only replaces the first occurrence with the result of calling $replacement_callback
    with the matched string.

  Does nothing, if this instance doesn't contain the $needle.

  This operation only replaces occurrences of $needle that are fully contained in $from-$to.
  */
  replace --all/bool=false needle/string from/int=0 to/int=size [replacement_callback] -> string:
    first_index := index_of needle from to
    if first_index < 0: return this
    if not all:
      replacement := replacement_callback.call needle
      bytes := ByteArray (size - needle.size + replacement.size)
      write_to_byte_array_ bytes 0 first_index 0
      replacement.write_to_byte_array_ bytes 0 replacement.size first_index
      write_to_byte_array_ bytes (first_index + needle.size) size (first_index + replacement.size)
      return bytes.to_string
    positions := [first_index]
    // We start by keeping track of one unique replacement string.
    // If the callback returns a different one, we start using a list for the remaining
    //   replacements.
    unique_replacement := replacement_callback.call needle
    replacements := []
    last_index := first_index
    while true:
      next_index := index_of needle (last_index + needle.size) to
      if next_index < 0: break

      positions.add next_index
      this_replacement := replacement_callback.call needle
      if not (replacements.is_empty and unique_replacement == this_replacement):
        replacements.add this_replacement
      last_index = next_index

    unique_replacement_count := positions.size - replacements.size
    result_size := size - (needle.size * positions.size)
        + unique_replacement_count * unique_replacement.size
        + (replacements.reduce --initial=0: |sum new| sum + new.size)

    bytes := ByteArray result_size
    next_from := 0
    next_to := 0
    for i := 0; i < positions.size; i++:
      this_position := positions[i]
      write_to_byte_array_ bytes next_from this_position next_to
      next_to += this_position - next_from
      next_from = this_position + needle.size
      this_replacement := i < unique_replacement_count
          ? unique_replacement
          : replacements[i - unique_replacement_count]
      this_replacement.write_to_byte_array_ bytes 0 this_replacement.size next_to
      next_to += this_replacement.size
    write_to_byte_array_ bytes next_from size next_to
    return bytes.to_string

  /**
  Replaces variables in a string with their values.
  The input is searched for variables, which are arbitrary
    text surrounded by the delimiters, $open and $close.
  By default it uses double braces, looking for `{{variable}}`.
  The variable names (with whitespace trimmed) are passed to the block and the
    return value from the block is stringified and used to replace the
    delimited text (including delimiters).
  If the block returns null then no change is performed at that
    point.  In this case the returned string will contain the delimiters, the
    contents and any white space.
  Returns the string with the substitutions performed.
  # Examples
  ```
  "foo {{bar}} baz".substitute: "-0-"              // => "foo -0- baz"
  "foo {{16}} baz".substitute: (int.parse it) + 1  // => "foo 17 baz"
  "x {{ y }} z".substitute: null                   // => "x {{ y }} z"
  "f [hest] b".substitute --open="[" --close="]": "horse"  // => "f horse b"
  "x {{b}} z".substitute: { "a": "hund", "b": "kat" }[it]  // => "x kat z"
  ```
  */
  substitute [block] -> string
      --open/string="{{"
      --close/string="}}":
    input := this
    parts := []
    while input != "":
      index := input.index_of open
      if index == -1:
        parts.add input
        break
      parts.add input[..index]
      substitution_size := input[index..].index_of close
      variable := input[index + open.size..index + substitution_size]
      input = input[index + substitution_size + close.size..]
      replacement := block.call variable.trim
      parts.add
          replacement == null ? "$open$variable$close" : replacement
    return parts.join ""

  /**
  Writes the raw UTF-8 bytes of the string to a new ByteArray.
  */
  to_byte_array -> ByteArray:
    byte_array := ByteArray size
    return write_to_byte_array_ byte_array 0 size 0

  /** Deprecated. Use $to_byte_array on a string slice instead. */
  to_byte_array start end -> ByteArray:
    byte_array := ByteArray end - start
    return write_to_byte_array_ byte_array start end 0

  /**
  Writes the raw UTF-8 bytes of the string to an existing ByteArray.
  */
  write_to_byte_array byte_array:
    return write_to_byte_array_ byte_array 0 size 0

  /**
  Writes the raw UTF-8 bytes of the string to the given
    offset of an existing ByteArray.
  */
  write_to_byte_array byte_array dest_index:
    return write_to_byte_array_ byte_array 0 size dest_index

  /** Deprecated. Use $write_to_byte_array on a string slice instead. */
  write_to_byte_array byte_array start end dest_index:
    return write_to_byte_array_ byte_array start end dest_index

  write_to_byte_array_ byte_array start end dest_index:
    #primitive.core.string_write_to_byte_array

class String_ extends string:
  constructor.private_:
    // Strings are only instantiated by the system. Never through Toit code.
    throw "UNREACHABLE"
    super.from_subclass_

  operator [] i/int -> int?:
    #primitive.core.string_at

  copy from/int to/int -> string:
    #primitive.core.string_slice

  hash_code:
    #primitive.core.string_hash_code

class StringSlice_ extends string:
  // This constant must be kept in sync with objects.cc so that no valid hash
  // can be 'NO_HASH_'.
  static NO_HASH_ ::= -1

  // The order of the fields matters, as the primitives access them directly.
  str_  / String_ // By having a `String_` here we can be more efficient.
  from_ / int
  to_   / int
  hash_ / int := NO_HASH_

  constructor .str_ .from_ .to_:
    size := str_.size
    if not 0 <= from_ <= to_ <= size: throw "OUT_OF_BOUNDS"
    // The from and to arguments must not be in the middle of Unicode sequences.
    if from_ != size and ((str_.raw_at_ from_) & 0b1100_0000) == 0b1000_0000:
      throw "ILLEGAL_UTF_8"
    if to_ != size and ((str_.raw_at_ to_) & 0b1100_0000) == 0b1000_0000:
      throw "ILLEGAL_UTF_8"
    super.from_subclass_

  operator [] i/int -> int?:
    actual_i := from_ + i
    if not from_ <= actual_i < to_: throw "OUT_OF_BOUNDS"
    return str_[actual_i]

  copy from/int to/int -> string:
    actual_from := from_ + from
    actual_to := from_ + to
    if not from_ <= actual_from <= actual_to <= to_: throw "OUT_OF_BOUNDS"
    return str_.copy actual_from actual_to

  hash_code -> int:
    if hash_ == NO_HASH_: hash_ = compute_hash_
    return hash_

  compute_hash_ -> int:
    #primitive.core.blob_hash_code

// Unsigned base 8 and base 16 stringification.
printf_style_int_stringify_ value/int base/int -> string:
  #primitive.core.printf_style_int64_to_string
