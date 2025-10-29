// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bitmap

import ..io as io

// Returns the number of bytes needed to code the char in UTF-8.
utf-8-bytes char:
  return write-utf-8-to-byte-array null 0 char

// Writes 1-4 bytes to the byte array, corresponding to the UTF-8 encoding of
// Unicode code point given as 'char'.  Returns the number of bytes written.
write-utf-8-to-byte-array byte-array position char:
  if 0 <= char <= 0x7f:
    if byte-array: byte-array[position] = char
    return 1
  if not 0 <= char < 0xd800:
    if not 0xe000 <= char <= 0x10ffff: throw "INVALID_ARGUMENT"
  bytes := 2
  mask := 0x1f
  shifted := 6
  while char >> shifted > mask:
    bytes++
    mask >>= 1
    shifted += 6
  if byte-array:
    unary-bits := (0xff00 >> bytes) & 0xff
    byte-array[position++] = (char >> shifted) | unary-bits
    while shifted > 0:
      shifted -= 6
      byte-array[position++] = 0x80 | ((char >> shifted) & 0x3f)
  return bytes

is-unicode-whitespace_ c/int -> bool:
  // This list should be kept in sync with the comment in $string.trim.
  return
    0x0009 <= c <= 0x000D or
      c == 0x0020 or
      c == 0x0085 or
      c == 0x00A0 or
      c == 0x1680 or
      0x2000 <= c <= 0x200A or
      c == 0x2028 or
      c == 0x2029 or
      c == 0x202F or
      c == 0x205F or
      c == 0x205f or
      c == 0x3000 or
      c == 0xFEFF

/**
A Unicode text object.
Strings are sequences of Unicode code points, stored in UTF-8 format.
This is a fully fledged class, not a 'primitive type'.
A string can only contain valid UTF-8 byte sequences.  To store arbitrary
  byte sequences or other encodings like ISO 8859, use $ByteArray.
Strings are immutable objects.
See more on strings at https://docs.toit.io/language/strings.
*/
abstract class string implements Comparable io.Data:
  static MIN-SLICE-SIZE_ ::= 16

  /**
  Constructs a single-character string from one Unicode code point.
  If $rune is greater than 0x7f, the result string will have
    size > 1 and contain more than one UTF-8 byte .

  # Examples
  ```
  str1 := string.from-rune 'a'  // -> "a"
  str2 := string.from-rune 0x41 // -> "A"
  str3 := string.from-rune 42   // -> "*"
  str4 := string.from-rune 7931 // -> "☃"
  ```
  */
  constructor.from-rune rune/int:
    #primitive.core.string-from-rune

  /**
  Constructs a string from a list of Unicode code points.
  All elements of the list must be in the Unicode range of 0 to 0x10ffff, inclusive.
  Since UTF-8 encoding is used, if any elements of the list are greater than
    the maximum ASCII value of 0x7f the size of the string will be greater than
    the size of the list.
  UTF-8 bytes are not valid input to this constructor.  If you have a ByteArray
    of UTF-8 bytes, use the $ByteArray.to-string method instead.

  # Examples
  ```
  str1 := string.from-runes ['a', 'b', 42]  // -> "ab*"
  str2 := string.from-runes [0x41]          // -> "A"
  str3 := string.from-runes [42]            // -> "*"
  str4 := string.from-runes [7931, 0x20ac]  // -> "☃€"
  ```
  */
  constructor.from-runes runes/List:
    length := 0
    runes.do:
      length += utf-8-bytes it
    ba := ByteArray length
    length = 0
    runes.do:
      length += write-utf-8-to-byte-array ba length it
    return ba.to-string

  constructor.from-subclass_:

  /**
  The size of this instance in UTF-8 code units (byte-sized).

  The string may have fewer runes (Unicode "code points") than its size.
  For example the string "Amélie" has a size of 7, but a `size --runes` of 6.
  */
  size -> int:
    #primitive.core.string-length

  /** Whether this instance is the empty string `""`. */
  is-empty -> bool:
    return size == 0

  /**
  Returns the number of runes (Unicode "code points") in this string.

  This operation takes linear time to complete as it runs through the whole string.
  */
  size --runes/True -> int:
    return rune-size_

  rune-size_ -> int:
    #primitive.core.string-rune-count

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

  Positions that would create an invalid UTF-8 sequence are rejected with
    an exception.

  # Examples
  ```
  str := "Hello, world!"
  hello := str[..5]
  world := str[7..]
  comma := str[5..6]
  print hello  // => "Hello"
  print comma  // => ","
  print world  // => "world!"
  amelie := "Amélie"
  amelie[2..3]  // Throws an exception.
  ```
  */
  // TODO(florian): make this an overloaded function. Currently we can't because
  // of abstract method restrictions.
  operator [..] --from=0 --to=size -> string:
    if not 0 <= from <= to <= size: throw "OUT_OF_BOUNDS"
    if from == 0 and to == size: return this
    if to - from < MIN-SLICE-SIZE_: return copy from to
    if this is String_: return StringSlice_ (this as String_) from to
    slice := this as StringSlice_
    return StringSlice_ slice.str_ (slice.from_ + from) (slice.from_ + to)

  /**
  The raw byte (Unicode codeunit) at position $i in the UTF-8 byte representation
    of this string.

  Contrary to $at this method never returns null.
  */
  at --raw/True i/int -> int:
    return raw-at_ i

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

  # Examples
  ```
  "Amélie".do --runes: print "$(%c it)" // A, m, é, l, i, e
  ```
  */
  do --runes/True [block] -> none:
    for i := 0; i < size; i++:
      rune := this[i]
      if rune: block.call rune

  /**
  Calls the given $block for every unicode character in the string.

  The argument to the block is an integer in the Unicode range of 0-0x10ffff,
    inclusive.
  The return value is assembled from the return values of the block.
  If a string is returned from the block it is inserted at that point in the
    return value.
  If a byte array is returned from the block it is converted to a string and
    treated like a string.  The byte array must contain whole, valid UTF-8
    sequences.
  If an integer is returned from the block it is treated as a Unicode code
    point, and the corresponding code point is inserted.
  If the block returns null, this is treated like the zero length string.
  If the block returns a list, then every element in the list
    is handled like the above actions, but this is only done for one level -
    lists of lists are not flattened in this way.
  To get a list or byte array as the return value instead of a string, use
    `str.to-byte-array.map` instead.

  # Examples.
  ```
  heavy-metalize str/string -> string:
    return str.flat_map: | c |
      {'o': 'ö', 'a': 'ä', 'u': 'ü', 'ä': "\u{20db}a"}.get c --if-absent=: c
  ```
  ```
  lower-case str/string -> string:
    return str.flat-map: | c | ('A' <= c <= 'Z') ? c - 'A' + 'a' : c
  ```
  */
  flat-map [block] -> string:
    prefix := ""
    byte-array := ByteArray (min 4 size)
    position := 0

    replace-block := : | replacement |
      if replacement is string or replacement is ByteArray:
        if position + replacement.size > byte-array.size:
          prefix += (byte-array.to-string 0 position) + replacement.to-string
          position = 0
          byte-array = ByteArray (byte-array.size * 1.5).to-int
        else:
          byte-array.replace position replacement
          position += replacement.size
      else if replacement is int:
        if position + (utf-8-bytes replacement) > byte-array.size:
          prefix += byte-array.to-string 0 position
          byte-array = ByteArray (byte-array.size * 1.5).to-int
          position = 0
        position += write-utf-8-to-byte-array byte-array position replacement
      else if replacement != null:
        throw "Invalid replacement"

    for i := 0; i < size; i++:
      rune := this[i]
      if rune:
        replacement := block.call rune
        if replacement is List:
          replacement.do: replace-block.call it
        else:
          replace-block.call replacement
    result := prefix + (byte-array.to-string 0 position)
    return result == this ? this : result

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

  If $force-valid is true, adjusts $from and $to so that they are valid substring indexes.

  If $from (resp. $to) points to the middle of a multi-byte sequence decreases the index
    until it points to the beginning of the sequence.

  Also see $rune-index.
  */
  copy from/int to/int=size --force-valid/bool -> string:
    if force-valid:
      from = rune-index from
      to = rune-index to
    return copy from to

  /** Equivalent to $copy, but can be used when you have either a ByteArray or a string. */
  to-string from=0 to=size -> string:
    return copy from to

  /**
  Returns the index of the rune pointed to by $index.

  Returns $index if it is equal to the size.
  Returns $index if it points to the beginning of a rune.
  Otherwise decreases $index until it points to the beginning of the multi-byte sequence.

  The parameter $index must satisfy: `0 <= index <= size`.
  */
  rune-index index/int -> int:
    if index == size: return index
    // TODO(florian): make this more efficient?
    while this[index] == null: index--
    return index

  safe-at_ index/int -> int:
    return index >= size ? -1 : this[index]


  /**
  Formats the $object according to the given $format.

  The normal way of using this functionality is through the
    string interpolation syntax - see
    https://docs.toit.io/language/strings/#string-interpolation.

  The $format description is very similar to `printf`.

  Extensions relative to printf:
  - `^` for centering.
  - 'b' for binary.

  Missing relative to printf: No support for `%g` or `%p`.

  The `%u` type treats integer as unsigned 64 bit integers.

  Like in printf the hexadecimal and octal format specifiers,
    %x and %o will treat all values as unsigned.  This also
    applies to the binary format specifier, %b.  See also
    $int.stringify.

  Format Description:
  ```
  [alignment][precision][type]
  alignment = flags<digits>
  flags = '-' | '^' | '>'   (> is default, can't be used in the syntax)
  precision = .<digits>
  type 'd' | 'f' | 's' | 'o' | 'x' | 'c' | 'b' | 'u'
  ```
  */
  static format format/string object -> string:
    pos := 0
    char := format.safe-at_ pos++
    alignment-type := '>'
    precision := null
    type := 's'
    // Read optional alignment.
    if char == '^' or char == '-':
      alignment-type = char
      char = format.safe-at_ pos++
    // Read optional field width.
    start := pos - 1
    zero-pad := char == '0'
    if zero-pad and alignment-type != '>': throw "ZERO_PADDING_ONLY_WITH_RIGHT_ALIGNMENT $format"
    while '0' <= char <= '9': char = format.safe-at_ pos++
    alignment-width := start == pos - 1
        ? 0
        : int.parse_ format start (pos - 1) --radix=10 --if-error=: throw it
    if char == '.':
      start = pos
      char = format.safe-at_ pos++
      while '0' <= char <= '9': char = format.safe-at_ pos++
      if start == pos - 1: throw "MISSING_PRECISION_IN_FORMAT $format"
      precision = int.parse format[start..pos - 1]
    if char == -1: throw "MISSING_TYPE_IN_FORMAT $format"
    type = char
    char = format.safe-at_ pos++
    if char != -1: throw "UNEXPECTED_TRAILING_CHARACTERS_IN_FORMAT $format"
    meat := ""
    meat-size := null
    if type == 's':
      meat = object.stringify
      meat-size = meat.size --runes
    else if type == 'f':
      d := object.to-float
      meat = precision ? (d.stringify precision) : d.stringify
    else if type == 'd': meat = object.to-int.stringify
    else if type == 'u': meat = object.to-int.stringify --uint64
    else if type == 'b': meat = printf-style-int-stringify_ object.to-int 2
    else if type == 'o': meat = printf-style-int-stringify_ object.to-int 8
    else if type == 'x': meat = printf-style-int-stringify_ object.to-int 16
    else if type == 'X':
      meat = printf-style-int-stringify_ object.to-int 16
      meat = (ByteArray meat.size: meat[it] >= 'a' ? meat[it] + 'A' - 'a' : meat[it]).to-string
    else if type == 'c':
      character := object.to-int
      ba := ByteArray (utf-8-bytes character)
      write-utf-8-to-byte-array ba 0 character
      meat = ba.to-string
      meat-size = 1
    else: throw "WRONG_TYPE_IN_FORMAT $format"
    if not meat-size: meat-size = meat.size
    if alignment-width < meat-size: return meat
    padding := alignment-width - meat-size
    if alignment-type == '-': return meat.pad_ 0 padding ' '
    if alignment-type == '>': return meat.pad_ padding 0 (zero-pad ? '0' : ' ')
    assert: alignment-type == '^'
    return meat.pad_ (padding / 2) (padding - padding / 2) ' '

  /**
  The hash code for this instance.

  This operation is in `O(1)`.
  */
  abstract hash-code

  raw-at_ n:
    #primitive.core.string-raw-at

  /**
  Concatenates this instance with the given $other string.
  */
  operator + other/string -> string:
    #primitive.core.string-add

  /**
  Concatenates $amount copies of this instance.

  The parameter $amount must be >= 0.
  */
  operator * amount/int -> string:
    if amount < 0: throw "Bad Argument"
    if amount == 0 or size == 0: return ""
    if amount == 1: return this
    new-size := size * amount
    array := ByteArray new-size
    bitmap.blit this array size --source-line-stride=0
    return array.to-string

  /** See $super. */
  operator == other:
    if other is not string: return false
    #primitive.core.blob-equals


  /**
  Whether this instance is less than $other.

  Uses $compare-to to determine the ordering of the two strings.
  */
  operator < other/string -> bool:
    return (compare-to other) == -1

  /**
  Whether this instance is less or equal to $other.

  Uses $compare-to to determine the ordering of the two strings.
  */
  operator <= other/string -> bool:
    return (compare-to other) != 1

  /**
  Whether this instance is greater than $other.

  Uses $compare-to to determine the ordering of the two strings.
  */
  operator > other/string -> bool:
    return (compare-to other) == 1

  /**
  Whether this instance is greater or equal to $other.

  Uses $compare-to to determine the ordering of the two strings.
  */
  operator >= other/string -> bool:
    return (compare-to other) != -1

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
  "a".compare-to "b"    // => -1
  "a".compare-to "a"    // => 0
  "b".compare-to "a"    // => 1
  "ab".compare-to "abc" // => -1
  "abc".compare-to "ab" // => 1
  "Amélie".compare-to "Amelie"  // => 1
  "Amélie".compare-to "Amzlie"  // => 1
  ```
  */
  compare-to other/string -> int:
    #primitive.core.string-compare

  /**
  Compares this instance with $other and calls $if-equal if the two are equal.

  See $compare-to for documentation on the ordering.

  The $if-equal block is called only if this instance and $other are equal.
  The $if-equal block should return -1, 0, or 1 (since it becomes the result of
    the call to this method).

  # Examples
  The $if-equal block allows easy chaining of `compare-to` calls.
  ```
  // In class A with fields str-field1 and str-field2:
  compare-to other/A -> int:
    return str-field1.compare-to other.str-field1 --if-equal=:
      str-field2.compare-to other.str-field2
  ```
  */
  compare-to other/string [--if-equal] -> int:
    result := compare-to other
    if result == 0: return if-equal.call
    return result

  stringify:
    return this

  /**
  Pads this instance with char on the left, until the total size of the string is $amount.

  Returns this instance directly if this instance is longer than $amount.

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
  pad --left/True=true amount/int char/int=' ' -> string:
    return pad_ (amount - size) 0 char

  /**
  Pads this instance with $char on the right, until the total size of the string is $amount.

  Returns this instance directly if this instance is longer than $amount.

  # Examples
  ```
  str := "foo"
  str.pad --right 5     // => "foo  "
  str.pad --right 5 '0' // => "foo00"

  str.pad --right 3     // => "foo"
  str.pad --right 1     // => "foo"
  ```
  */
  pad --right/True  amount/int char/int=' ' -> string:
    return pad_ 0 (amount - size) char

  /**
  Pads this instance with $char on the left and right, until the total size of the string is $amount.

  Returns a string where this instance is centered. If the padding can't be divided evenly, adds more
    padding to the right.

  Returns this instance directly if this instance is longer than $amount.

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
  pad --center/True amount/int char/int=' ' -> string:
    padding := amount - size
    left := padding / 2
    right := padding - left
    return pad_ left right char

  pad_ left right char -> string:
    if left < 0 or right < 0: return this
    width := utf-8-bytes char
    array := ByteArray (left + right) * width + size
    pos := 0;
    left.repeat: pos += write-utf-8-to-byte-array array pos char
    write-to-byte-array_ array 0 size pos
    pos += size
    right.repeat: pos += write-utf-8-to-byte-array array pos char
    return array.to-string

  /**
  Whether this instance starts with the given $prefix.
  */
  starts-with prefix/string -> bool:
    return matches prefix --at=0

  /**
  Whether this instance ends with the given $suffix.
  */
  ends-with suffix/string -> bool:
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

  # Examples
  ```
  "Toad".glob "Toad"   // => true
  "Toad".glob "To?d"   // => true
  "Toad".glob "To"     // => false
  "To*d".glob "To\\*d" // => true
  "Toad".glob "To\\*d" // => false
  ```
  */
  glob pattern/string -> bool:
    return glob_ pattern --position=0

  glob_ pattern/string --position/int -> bool:
    pattern-pos := 0
    while pattern-pos < pattern.size or position < size:
      if pattern-pos < pattern.size:
        pattern-char := pattern[pattern-pos]
        if pattern-char == '?':
          if position < size:
            pattern-pos += utf-8-bytes pattern-char
            position += utf-8-bytes this[position]
            continue
        else if pattern-char == '*':
          sub-pattern := pattern.copy pattern-pos + 1
          while position <= size:
            if glob_ sub-pattern --position=position: return true
            position += position == size ? 1 : utf-8-bytes this[position]
        else if position < size and ((pattern-char == '\\') or (this[position] == pattern-char)):
          if pattern-char == '\\':
            if pattern-pos >= pattern.size: return false
            pattern-pos++
            if this[position] != pattern[pattern-pos]: return false
          pattern-pos += utf-8-bytes pattern-char
          position += utf-8-bytes this[position]
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
  "foobar".index-of "foo"  // => 0
  "foobar".index-of "bar"  // => 3
  "foo".index-of "bar"     // => -1

  "foobarfoo".index-of "foo"           // => 0
  "foobarfoo".index-of "foo" 1         // => 6
  "foobarfoo".index-of "foo" 1 8       // => -1

  // Invalid ranges:
  "foobarfoo".index-of "foo" -1 999    // Throws.
  "foobarfoo".index-of "foo" 1 999     // Throws.

  "".index-of "" 0 0   // => 0
  "".index-of "" -3 -3 // => Throws
  "".index-of "" 2 2   // => Throws

  // Last:
  "foobarfoo".index-of --last "foo"           // => 6
  "foobarfoo".index-of --last "foo" 1         // => 6
  "foobarfoo".index-of --last "foo" 1 6       // => 0
  "foobarfoo".index-of --last "foo" 0 1       // => 0
  "foobarfoo".index-of --last "foo" 0 8       // => 0

  "foobarfoo".index-of --last "gee"           // => -1
  "foobarfoo".index-of --last "foo" 1 5       // => -1
  "foobarfoo".index-of --last "foo" 0 8       // => 0
  ```
  */
  index-of --last/bool=false needle/string from/int=0 to/int=size -> int:
    return index-of --last=last needle from to --if-absent=: -1

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

  Calls $if-absent with this instance if $needle is not found, and returns the result of that call.

  # Examples
  Also see $index-of for more examples.
  ```
  "foo".index_of "bar" --if-absent=: it.size            // => 3 (the size of "foo")
  "foobarfoo".index_of "foo" 1 8 --if-absent=: 499      // => 499
  "".index_of "" -3 -3 --if-absent=: throw "not found"  // Error
  "".index_of "" 2 2   --if-absent=: -1                 // => -1
  "foobarfoo".index_of "foo" 1 8 --if-absent=: 42       // => 42
  ```
  */
  index-of --last/bool=false needle/string from/int=0 to/int=size [--if-absent]:
    if not 0 <= from <= to <= size: throw "BAD ARGUMENTS"
    limit := to - needle.size
    if not last:
      for i := from; i <= limit; i++:
        if matches needle --at=i: return i
    else:
      for i := limit; i >= from; i--:
        if matches needle --at=i: return i
    return if-absent.call this

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
      if not is-unicode-whitespace_ c: break
    end := size
    for ; end > start; end--:
      c := this[end - 1]
      if c == null: continue  // Multi-byte UTF-8 character.
      if not is-unicode-whitespace_ c: break
    // If the last non-whitespace character is a multi-byte UTF-8 character
    //   we have to include them. Move forward again to find all of them.
    while end < size and this[end] == null: end++
    return this[start..end]


  /**
  Removes leading whitespace.
  Variant of $(trim).
  */
  trim --left/True -> string:
    size.repeat:
      c := this[it]
      if c != null and not is-unicode-whitespace_ c:
        return this[it..]
    return ""

  /**
  Removes trailing whitespace.
  Variant of $(trim).
  */
  trim --right/True -> string:
    size.repeat:
      c := this[size - 1 - it]
      if c != null and not is-unicode-whitespace_ c:
        // If the last non-whitespace character is a multi-byte UTF-8 character
        //   we have to include them. Move forward again to find all of them.
        end := size - it
        while end < size and this[end] == null: end++
        return this[..end]
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
  trim --left/True prefix/string -> string:
    return trim --left prefix --if-absent=: it

  /**
  Removes a leading $prefix.

  Calls $if-absent if this instance does not start with $prefix. The argument
    to the block is this instance.

  # Examples
  ```
  "https://www.example.com".trim --left "http://" --if-absent=: it.trim --left "https://"  // => "www.example.com"
  str := "foobar"
  str.trim --left "foo" --if-absent=: "not_used" // => "bar"
  str.trim --left ""    --if-absent=: "not_used" // => "foobar"
  str.trim --left "gee" --if-absent=: it         // => "foobar"   (the default behavior)
  str.trim --left "gee" --if-absent=: throw "missing prefix" // ERROR
  ```
  */
  trim --left/True prefix/string [--if-absent] -> string:
    if not starts-with prefix: return if-absent.call this
    return this[prefix.size..]

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
  trim --right/True suffix/string -> string:
    return trim --right suffix --if-absent=: it

  /**
  Removes a trailing $suffix.

  Calls $if-absent if this instance does not end with $suffix. The argument
    to the block is this instance.

  # Examples
  ```
  str := "foobar"
  str.trim --right "bar" --if-absent=: "not_used" // => "bar"
  str.trim --right ""    --if-absent=: "not_used" // => "foobar"
  str.trim --right "gee" --if-absent=: it         // => "foobar"   (the default behavior)
  str.trim --right "gee" --if-absent=: throw "missing suffix" // ERROR
  ```
  */
  trim --right/True suffix/string [--if-absent] -> string:
    if not ends-with suffix: return if-absent.call this
    return this[..size - suffix.size]

  static TO-UPPER-TABLE_ ::= #[
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

  static TO-LOWER-TABLE_ ::= TO-UPPER-TABLE_[32..]

  /**
  Returns a string where all ASCII lower case characters have
    been replaced with their upper case equivalents.
  Non-ASCII characters are unchanged.
  */
  to-ascii-upper -> string:
    return case-helper_ TO-UPPER-TABLE_

  /**
  Returns a string where all ASCII upper case characters have
    been replaced with their lower case equivalents.
  Non-ASCII characters are unchanged.
  */
  to-ascii-lower -> string:
    return case-helper_ TO-LOWER-TABLE_

  case-helper_ table/ByteArray -> string:
    if size == 0: return this
    single-byte := #[0]
    // By using "OR" as an operation and a pixel stride of 0 we can condense
    // the search for characters with the wrong case into a single byte,
    // avoiding an allocation of a new byte array and string in the cases
    // where it is not needed.
    bitmap.blit this single-byte size
        --lookup-table=table
        --operation=bitmap.OR
        --destination-pixel-stride=0
    if single-byte[0] == 0: return this
    // Since characters with the wrong case were found we create a new string
    // using a temporary byte array.
    bytes := to-byte-array
    bitmap.blit bytes bytes bytes.size --lookup-table=table --operation=bitmap.XOR
    return bytes.to-string

  /**
  Returns true iff the string has no non-ASCII characters in it.
  The implementation is optimized, but it takes linear time in the size of the
    string.
  */
  contains-only-ascii -> bool:
    return size == (size --runes)

  /**
  Splits this instance at $separator.

  If $at-first is false (the default) splits at *every* occurrence of $separator.
  If $at-first is true, splits only at the first occurrence of $separator.

  If $drop-empty is true, then empty strings are ignored and silently dropped.
    This happens before a call to $process-part.

  Calls $process-part for each part. It $drop-empty is false and this instance
    starts or ends with a $separator, then $process-part is invoked with the
    empty string first and last, respectively.

  Splits are never in the middle of a UTF-8 multi-byte sequence. This is
    normally a consequence of the seperator (as well as this instance) being
    well-formed UTF-8. However, it is explicitly enforced for the zero length
    separator (the empty string).

  As a special case the empty separator does not result in a zero length string as
    the first and last entries, even though the empty separator can be found at
    both ends.  However if $at-first is true and the separator is empty then the
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

  "Toad the Wet Sprocket".split --at-first "e": print it  // prints "Toad th", " Wet Sprocket"
  " the dust ".split            --at-first " ": print it  // prints "", "the dust "
  gadsby.split                  --at-first "e": print it  // prints the contents of gadsby

  "abc".split  --at-first "":    print it     // prints "a" and "bc"
  "foo".split  --at-first "foo": print it     // prints "" and ""
  "afoo".split --at-first "foo": print it     // prints "a" and ""
  "foob".split --at-first "foo": print it     // prints "" and "b"
  "".split     --at-first "":    print it     // This is an error.
  "a".split    --at-first "":    print it     // prints "a" and ""

  "foo".split "foo" --drop-empty: print it                 // Doesn't print.
  "afoo".split "foo" --drop-empty: print it                 // prints "a"
  ```
  */
  split --at-first/bool=false separator/string --drop-empty/bool=false [process-part] -> none:
    if drop-empty:
      split --at-first=at-first separator:
        if it != "": process-part.call it
      return

    if separator == "":
      if at-first:
        if size == 0: throw "INVALID_ARGUMENT"
        len := utf-8-bytes this[0]
        process-part.call this[..len]
        process-part.call this[len..]
        return
      split-everywhere_ process-part
      return
    subject := this
    pos := 0
    while pos <= size:
      new-pos := subject.index-of separator pos --if-absent=:
        // No match.
        process-part.call subject[pos..size]
        return
      process-part.call subject[pos..new-pos]
      pos = new-pos + separator.size
      if at-first:
        process-part.call subject[pos..]
        return

  /**
  Splits this instance at $separator.

  Returns a list of the separated parts.

  If $at-first is false (the default) splits at *every* occurrence of $separator.
  If $at-first is true, splits only at the first occurrence of $separator.

  If $drop-empty is true, then empty strings are not included in the result.

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

  "Toad the Wet Sprocket".split --at-first "e"  // => ["Toad th", " Wet Sprocket"]
  " the dust ".split            --at-first " "  // => ["", "the dust "]
  gadsby.split                  --at-first "e"  // => [gadsby]

  "abc".split  --at-first ""      // => ["", "abc"]
  "foo".split  --at-first "foo"   // => ["", ""]
  "afoo".split --at-first "foo"   // => ["a", ""]
  "foob".split --at-first "foo"   // => ["", "b"]
  "".split     --at-first ""      // => [""]
  ```
  */
  split --at-first/bool=false separator/string --drop-empty/bool=false -> List/*<string>*/ :
    res := []
    split --at-first=at-first --drop-empty=drop-empty separator:
      res.add it
    return res

  split-everywhere_ [process-part]:
    subject := this
    size.repeat:
      c := subject[it]
      if c: process-part.call (subject.copy it it + (utf-8-bytes c))

  /**
  Returns whether $needle is present in this instance.

  The optional parameters $from and $to delimit the range in which
    the $needle is searched in. The $needle must be fully contained in
    the range $from..$to (as if taking a $copy with these parameters) to
    return true.

  The range $from - $to must be valid and satisfy 0 <= $from <= $to <= $size.
  */
  contains needle/string from/int=0 to/int=size -> bool:
    return (index-of needle from to) >= 0

  /**
  Replaces the given $needle with the $replacement string.

  If $all is true, replaces all occurrences of $needle. Otherwise, only replaces the first occurrence.

  Does nothing, if this instance doesn't contain the $needle.

  This operation only replaces occurrences of $needle that are fully contained in $from-$to.
  */
  replace --all/bool=false needle/string replacement/string from/int=0 to/int=size -> string:
    return replace --all=all needle from to: replacement

  /**
  Replaces the given $needle with the result of calling $replacement-callback.

  If $all is true, replaces all occurrences of $needle. For each found occurrence calls the
    $replacement-callback with the matched string as argument.

  If $all is false (the default), only replaces the first occurrence with the result
    of calling $replacement-callback with the matched string.

  Does nothing, if this instance doesn't contain the $needle.

  This operation only replaces occurrences of $needle that are fully contained in $from-$to.
  */
  replace --all/bool=false needle/string from/int=0 to/int=size [replacement-callback] -> string:
    first-index := index-of needle from to
    if first-index < 0: return this
    if not all:
      replacement := replacement-callback.call needle
      bytes := ByteArray (size - needle.size + replacement.size)
      write-to-byte-array_ bytes 0 first-index 0
      replacement.write-to-byte-array_ bytes 0 replacement.size first-index
      write-to-byte-array_ bytes (first-index + needle.size) size (first-index + replacement.size)
      return bytes.to-string
    positions := [first-index]
    // We start by keeping track of one unique replacement string.
    // If the callback returns a different one, we start using a list for the remaining
    //   replacements.
    unique-replacement := replacement-callback.call needle
    replacements := []
    last-index := first-index
    while true:
      next-index := index-of needle (last-index + needle.size) to
      if next-index < 0: break

      positions.add next-index
      this-replacement := replacement-callback.call needle
      if not (replacements.is-empty and unique-replacement == this-replacement):
        replacements.add this-replacement
      last-index = next-index

    unique-replacement-count := positions.size - replacements.size
    result-size := size - (needle.size * positions.size)
        + unique-replacement-count * unique-replacement.size
        + (replacements.reduce --initial=0: |sum new| sum + new.size)

    bytes := ByteArray result-size
    next-from := 0
    next-to := 0
    for i := 0; i < positions.size; i++:
      this-position := positions[i]
      write-to-byte-array_ bytes next-from this-position next-to
      next-to += this-position - next-from
      next-from = this-position + needle.size
      this-replacement := i < unique-replacement-count
          ? unique-replacement
          : replacements[i - unique-replacement-count]
      this-replacement.write-to-byte-array_ bytes 0 this-replacement.size next-to
      next-to += this-replacement.size
    write-to-byte-array_ bytes next-from size next-to
    return bytes.to-string

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
      index := input.index-of open
      if index == -1:
        parts.add input
        break
      parts.add input[..index]
      substitution-size := input[index..].index-of close
      variable := input[index + open.size..index + substitution-size]
      input = input[index + substitution-size + close.size..]
      replacement := block.call variable.trim
      parts.add
          replacement == null ? "$open$variable$close" : replacement
    return parts.join ""

  /**
  Writes the raw UTF-8 bytes of the string to a new ByteArray.
  */
  to-byte-array -> ByteArray:
    byte-array := ByteArray size
    return write-to-byte-array_ byte-array 0 size 0

  /** Deprecated. Use $to-byte-array on a string slice instead. */
  to-byte-array start end -> ByteArray:
    byte-array := ByteArray end - start
    return write-to-byte-array_ byte-array start end 0

  /**
  Converts the string to little-endian UTF-16 and writes the raw UTF-16 bytes
    to a new ByteArray.
  */
  to-utf-16 -> ByteArray:
    #primitive.core.string-to-utf-16

  /**
  Treats the byte array as little endian UTF-16 and converts it to a string.
  If the byte array is not a valid UTF-16 string, error characters
    (U+FFFD) are inserted as replacements. Unpaired surrogates are
    considered invalid and replaced with the error character.
  */
  constructor.from-utf-16 byte-array/ByteArray:
    return string-from-utf-16_ byte-array

  /**
  Writes the raw UTF-8 bytes of the string to an existing ByteArray.
  */
  write-to-byte-array byte-array/ByteArray:
    return write-to-byte-array_ byte-array 0 size 0

  /**
  Writes the raw UTF-8 bytes of the string to the given
    offset of an existing ByteArray.
  */
  write-to-byte-array byte-array/ByteArray dest-index:
    return write-to-byte-array_ byte-array 0 size dest-index

  /** Deprecated. Use $write-to-byte-array on a string slice instead. */
  write-to-byte-array byte-array/ByteArray start end dest-index:
    return write-to-byte-array_ byte-array start end dest-index

  write-to-byte-array_ byte-array/ByteArray start end dest-index:
    #primitive.core.string-write-to-byte-array

  byte-size -> int:
    return size

  byte-slice from to/int -> io.Data:
    if this is String_: return StringByteSlice_ (this as String_) from to
    if not 0 <= from <= to <= byte-size: throw "OUT_OF_BOUNDS"
    slice := this as StringSlice_
    return StringByteSlice_ slice.str_ (slice.from_ + from) (slice.from_ + to)

  byte-at index/int -> int:
    return raw-at_ index

  write-to-byte-array byte-array/ByteArray --at/int from/int to/int:
    write-to-byte-array_ byte-array from to at

class String_ extends string:
  constructor.private_:
    // Strings are only instantiated by the system. Never through Toit code.
    throw "UNREACHABLE"
    super.from-subclass_

  operator [] i/int -> int?:
    #primitive.core.string-at

  copy from/int to/int -> string:
    #primitive.core.string-slice

  hash-code:
    #primitive.core.string-hash-code

class StringSlice_ extends string:
  // This constant must be kept in sync with objects.cc so that no valid hash
  // can be 'NO_HASH_'.
  static NO-HASH_ ::= -1

  // The order of the fields matters, as the primitives access them directly.
  str_  / String_ // By having a `String_` here we can be more efficient.
  from_ / int
  to_   / int
  hash_ / int := NO-HASH_

  constructor .str_ .from_ .to_:
    size := str_.size
    if not 0 <= from_ <= to_ <= size: throw "OUT_OF_BOUNDS"
    // The from and to arguments must not be in the middle of Unicode sequences.
    if from_ != size and ((str_.raw-at_ from_) & 0b1100_0000) == 0b1000_0000:
      throw "ILLEGAL_UTF_8"
    if to_ != size and ((str_.raw-at_ to_) & 0b1100_0000) == 0b1000_0000:
      throw "ILLEGAL_UTF_8"
    super.from-subclass_

  operator [] i/int -> int?:
    actual-i := from_ + i
    if not from_ <= actual-i < to_: throw "OUT_OF_BOUNDS"
    return str_[actual-i]

  copy from/int to/int -> string:
    actual-from := from_ + from
    actual-to := from_ + to
    if not from_ <= actual-from <= actual-to <= to_: throw "OUT_OF_BOUNDS"
    return str_.copy actual-from actual-to

  hash-code -> int:
    if hash_ == NO-HASH_: hash_ = compute-hash_
    return hash_

  compute-hash_ -> int:
    #primitive.core.blob-hash-code

class StringByteSlice_ implements io.Data:
  str_ / String_
  from_ / int
  to_ / int

  constructor .str_ .from_ .to_:

  // TODO(florian): this method is only here for backwards-compatability.
  // Some methods used to take 'any' and then take the 'size' of it.
  // Once we have migrated all these locations to use 'io.Data' and 'byte-size', it
  // can be removed.
  size -> int:
    return byte-size

  byte-size -> int:
    return to_ - from_

  byte-slice from/int to/int -> io.Data:
    actual-from := from_ + from
    actual-to := from_ + to
    if not from_ <= actual-from <= actual-to <= to_: throw "OUT_OF_BOUNDS"
    return StringByteSlice_ str_ actual-from actual-to

  byte-at index/int -> int:
    if not 0 <= index < (to_ - from_): throw "OUT_OF_BOUNDS"
    actual-index := from_ + index
    return str_.byte-at actual-index

  write-to-byte-array byte-array/ByteArray --at/int from/int to/int -> none:
    actual-from := from_ + from
    actual-to := from_ + to
    if not from_ <= actual-from <= actual-to <= to_: throw "OUT_OF_BOUNDS"
    str_.write-to-byte-array --at=at byte-array actual-from actual-to

// Unsigned base 2, 8, and 16 stringification.
printf-style-int-stringify_ value/int base/int -> string:
  #primitive.core.printf-style-int64-to-string

string-from-utf-16_ byte-array/ByteArray -> string:
  #primitive.core.utf-16-to-string
