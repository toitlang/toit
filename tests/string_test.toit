// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect_error name [code]:
  expect_equals
    name
    catch code

expect_out_of_bounds [code]:
  expect_error "OUT_OF_BOUNDS" code

expect_illegal_utf_8 [code]:
  expect_error "ILLEGAL_UTF_8" code

expect_invalid_argument [code]:
  expect_error "INVALID_ARGUMENT" code

expect_wrong_object_type [code]:
  exception_name := catch code
  expect
      exception_name == "WRONG_OBJECT_TYPE" or exception_name == "AS_CHECK_FAILED"

test_escaped_characters:
  expect_equals "\x00" "\0"
  expect_equals "\x07" "\a"
  expect_equals "\x08" "\b"
  expect_equals "\x0C" "\f"
  expect_equals "\x0A" "\n"
  expect_equals "\x0D" "\r"
  expect_equals "\x09" "\t"
  expect_equals "\x0B" "\v"
  expect_equals "\x24" "\$"
  expect_equals "\x5C" "\\"
  expect_equals "\x22" "\""
  expect_equals "" """\
"""

  expect_equals "\x00"[0] 0x0
  expect_equals "\x0A"[0] 0xa
  expect_equals "\x0F"[0] 0xf
  expect_equals "\x99"[0] 0x99
  expect_equals "\xaa"[0] 0xaa
  expect_equals "\xff"[0] 0xff
  expect_equals "Z\x00Z"[0] 'Z'
  expect_equals "Z\x00Z"[1] 0x0
  expect_equals "Z\x00Z"[2] 'Z'
  expect_equals "Z\x0AZ"[0] 'Z'
  expect_equals "Z\x0AZ"[1] 0xa
  expect_equals "Z\x0AZ"[2] 'Z'
  expect_equals "Z\x0FZ"[0] 'Z'
  expect_equals "Z\x0FZ"[1] 0xf
  expect_equals "Z\x0FZ"[2] 'Z'
  expect_equals "Z\x99Z"[0] 'Z'
  expect_equals "Z\x99Z"[1] 0x99
  expect_equals "Z\x99Z"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\xaaZ"[0] 'Z'
  expect_equals "Z\xaaZ"[1] 0xaa
  expect_equals "Z\xaaZ"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\xffZ"[0] 'Z'
  expect_equals "Z\xffZ"[1] 0xff
  expect_equals "Z\xffZ"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\u0060Z"[0] 'Z'
  expect_equals "Z\u0060Z"[1] 0x60
  expect_equals "Z\u0060Z"[2] 'Z'
  expect_equals "Z\u0099Z"[0] 'Z'
  expect_equals "Z\u0099Z"[1] 0x99
  expect_equals "Z\u0099Z"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\u0160Z"[0] 'Z'
  expect_equals "Z\u0160Z"[1] 0x160
  expect_equals "Z\u0160Z"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\u1160Z"[0] 'Z'
  expect_equals "Z\u1160Z"[1] 0x1160
  expect_equals "Z\u1160Z"[4] 'Z'  // The encoded character requires three bytes.

  expect_equals '\x00' 0x0
  expect_equals '\x0A' 0xa
  expect_equals '\x0F' 0xf
  expect_equals '\x99' 0x99
  expect_equals '\xaa' 0xaa
  expect_equals '\xff' 0xff

  expect_equals "\x{0}"[0] 0x0
  expect_equals "\x{A}"[0] 0xa
  expect_equals "\x{F}"[0] 0xf
  expect_equals "\x{9}9"[0] 0x9
  expect_equals "\x{99}"[0] 0x99
  expect_equals "\x{a}a"[0] 0xa
  expect_equals "\x{aa}"[0] 0xaa
  expect_equals "\x{ff}"[0] 0xff
  expect_equals "Z\x{0}Z"[0] 'Z'
  expect_equals "Z\x{0}Z"[1] 0x0
  expect_equals "Z\x{0}Z"[2] 'Z'
  expect_equals "Z\x{A}Z"[0] 'Z'
  expect_equals "Z\x{A}Z"[1] 0xa
  expect_equals "Z\x{A}Z"[2] 'Z'
  expect_equals "Z\x{F}Z"[0] 'Z'
  expect_equals "Z\x{F}Z"[1] 0xf
  expect_equals "Z\x{F}Z"[2] 'Z'
  expect_equals "Z\x{9}9"[0] 'Z'
  expect_equals "Z\x{9}9"[1] 0x9
  expect_equals "Z\x{9}9"[2] '9'
  expect_equals "Z\x{99}Z"[0] 'Z'
  expect_equals "Z\x{99}Z"[1] 0x99
  expect_equals "Z\x{99}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\x{a}a"[0] 'Z'
  expect_equals "Z\x{a}a"[1] 0xa
  expect_equals "Z\x{a}a"[2] 'a'
  expect_equals "Z\x{aa}Z"[0] 'Z'
  expect_equals "Z\x{aa}Z"[1] 0xaa
  expect_equals "Z\x{aa}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\x{ff}Z"[0] 'Z'
  expect_equals "Z\x{ff}Z"[1] 0xff
  expect_equals "Z\x{ff}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\u{000060}Z"[0] 'Z'
  expect_equals "Z\u{000060}Z"[1] 0x60
  expect_equals "Z\u{000060}Z"[2] 'Z'
  expect_equals "Z\u{000099}Z"[0] 'Z'
  expect_equals "Z\u{000099}Z"[1] 0x99
  expect_equals "Z\u{000099}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\u{000160}Z"[0] 'Z'
  expect_equals "Z\u{000160}Z"[1] 0x160
  expect_equals "Z\u{000160}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect_equals "Z\u{001160}Z"[0] 'Z'
  expect_equals "Z\u{001160}Z"[1] 0x1160
  expect_equals "Z\u{001160}Z"[4] 'Z'  // The encoded character requires three bytes.
  expect_equals "Z\u{011160}Z"[0] 'Z'
  expect_equals "Z\u{011160}Z"[1] 0x11160
  expect_equals "Z\u{011160}Z"[5] 'Z'  // The encoded character requires four bytes.
  expect_equals "Z\u{10FFFF}Z"[0] 'Z'
  expect_equals "Z\u{10FFFF}Z"[1] 0x10FFFF
  expect_equals "Z\u{10FFFF}Z"[5] 'Z'  // The encoded character requires four bytes.

  expect_equals '\x{0}' 0x0
  expect_equals '\x{A}' 0xa
  expect_equals '\x{F}' 0xf
  expect_equals '\x{99}' 0x99
  expect_equals '\x{aa}' 0xaa
  expect_equals '\x{ff}' 0xff

  expect_equals '\u{1}' 0x1
  expect_equals '\u{12}' 0x12
  expect_equals '\u{123}' 0x123
  expect_equals '\u{1234}' 0x1234
  expect_equals '\u{12345}' 0x12345
  expect_equals '\u{10FFFF}' 0x10FFFF

  expect_equals '\u0001' 0x1
  expect_equals '\u0012' 0x12
  expect_equals '\u0123' 0x123
  expect_equals '\u1234' 0x1234

check_to_string bytes str:
  // The input is an array, because that's what we have literal syntax for, so
  // we need to convert to an array.
  byte_array := ByteArray bytes.size + 2
  i := 0
  byte_array[i++] = '_'
  bytes.do: byte_array[i++] = it
  byte_array[i++] = '_'
  expect_equals "_$(str)_" byte_array.to_string

  // Also check the reverse direction
  byte_array = ByteArray 30
  30.repeat: byte_array[it] = '*'

  write_utf_8_to_byte_array byte_array 2 str[0]
  expect_equals '*' byte_array[0]
  expect_equals '*' byte_array[1]
  expect_equals '*' byte_array[str.size + 2]
  i = 2
  bytes.do: expect_equals it byte_array[i++]

check_illegal_utf_8 bytes expectation = null:
  byte_array := ByteArray bytes.size: bytes[it]
  string_with_replacements := byte_array.to_string_non_throwing
  expect (string_with_replacements.index_of "\ufffd") != -1
  if expectation: expect_equals string_with_replacements expectation
  expect_illegal_utf_8: byte_array.to_string

test_conversion_from_byte_array:
  check_to_string [0] "\x00"
  check_to_string [65] "A"
  check_to_string [0xc3, 0xa6] "æ"                       // Ae ligature.
  check_to_string [0xd0, 0x90] "А"                       // Cyrillic capital A.
  check_to_string [0xdf, 0xb9] "߹"                       // N'Ko exclamation mark.
  check_to_string [0xe2, 0x82, 0xac] "€"                 // Euro sign.
  check_to_string [0xe2, 0x98, 0x83] "☃"                 // Snowman.
  check_to_string [0xf0, 0x9f, 0x99, 0x88] "🙈"          // See-no-evil monkey.
  check_illegal_utf_8 [244, 65, 48] "\uFFFDA0"           // Low continuation bytes.
  check_illegal_utf_8 [244, 244, 48] "\uFFFD0"           // High continuation bytes.
  check_illegal_utf_8 [48, 244] "0\uFFFD"                // Missing continuation bytes.
  continuations := List 10 0xbf
  continuations[0] = 0x80
  check_illegal_utf_8 continuations "\uFFFD"             // Unexpected continuation byte.
  continuations[0] = 0xf8
  check_illegal_utf_8 continuations "\uFFFD"             // 5-byte sequence.
  continuations[0] = 0xfc
  check_illegal_utf_8 continuations "\uFFFD"             // 6-byte sequence.
  continuations[0] = 0xfe
  check_illegal_utf_8 continuations "\uFFFD"             // 7-byte sequence.
  continuations[0] = 0xff
  check_illegal_utf_8 continuations "\uFFFD"             // 8-byte sequence.
  check_illegal_utf_8 [0xc0, 0xdc] "\uFFFD"              // Overlong encoding of backslash.
  check_illegal_utf_8 [0xc1, 0xdf] "\uFFFD"              // Overlong encoding of DEL.
  check_illegal_utf_8 [0xe0, 0x9f, 0xbf] "\uFFFD"        // Overlong encoding of character 0x7ff.
  check_illegal_utf_8 [0xe0, 0x9f, 0xb9] "\uFFFD"        // Overlong encoding of N'Ko exclamation mark.
  check_illegal_utf_8 [0xf0, 0x82, 0x98, 0x83] "\uFFFD"  // Overlong encoding of Unicode snowman.
  check_to_string [0xed, 0x9f, 0xbf] "퟿"                 // 0xd7ff: Last (Hangul) character before the surrogate block.
  check_illegal_utf_8 [0xed, 0xa0, 0x80] "\uFFFD"        // 0xd800: First surrogate.
  check_to_string [0xee, 0x80, 0x80] ""                 // 0xe000: First private use character.
  // The next one is the Apple logo on macOS, and it's the Klingon mummification
  // glyph on Linux, which tells you all you need to know about those two operating systems.
  check_to_string [0xef, 0xA3, 0xBF] ""                 // 0xf8ff: Last private use character.
  check_illegal_utf_8 [0xed, 0xbf, 0xbf] "\uFFFD"        // 0xdfff: Last surrogate.
  check_to_string [0xf4, 0x8f, 0xbf, 0xbf] "􏿿"           // 0x10ffff: Last Unicode character.
  check_illegal_utf_8 [0xf4, 0x90, 0x80, 0x80] "\uFFFD"  // 0x110000: First out-of-range value.
  check_illegal_utf_8 [0xf5, 0x80, 0x80, 0x80] "\uFFFD"  // All UTF-8 sequences starting with f5, f6 or f7 ...
  check_illegal_utf_8 [0xf6, 0x80, 0x80, 0x80] "\uFFFD"  // ... are out of the 0x10ffff range.
  check_illegal_utf_8 [0xf7, 0x80, 0x80, 0x80] "\uFFFD"

  check_illegal_utf_8 ['x', 0x80, 'y'] "x\uFFFDy"
  check_illegal_utf_8 ['x', 0xFF, 'y'] "x\uFFFDy"
  check_illegal_utf_8 ['x', 0xC0, 0x00, 'y'] "x\uFFFD\0y"
  check_illegal_utf_8 ['x', 0xC0, 0x80, 'y'] "x\uFFFDy"
  check_illegal_utf_8 ['x', 0xC0, 0x80, 'y', 0x80] "x\uFFFDy\uFFFD"
  check_illegal_utf_8 ['x', 0xC0, 0x80, 'y', 0xC0] "x\uFFFDy\uFFFD"

  str := "foobar"
  byte_array := ByteArray 10000
  10000.repeat: byte_array[it] = '*'
  write_utf_8_to_byte_array byte_array 2 str[0]
  big_string := byte_array.to_string
  expect_equals big_string big_string
  10000.repeat: expect_equals byte_array[it] (big_string.at --raw it)
  expect_equals 10000 big_string.size

test_string_at:
  big_repetitions := 100
  // The UTF-8 encoding means that byte positions after two-byte characters
  // like æ, ø, å are not valid, and return null when accessed with [].
  str1 := "Søen så sær ud!"
  long_str1 := str1 * big_repetitions
  long_str1.to_byte_array
  expect_equals str1 str1.to_byte_array.to_string
  expect_equals long_str1 long_str1.to_byte_array.to_string
  expect_out_of_bounds: str1[str1.size]
  expect_out_of_bounds: long_str1[long_str1.size]
  test_soen := (: |s offset|
    i := offset
    expect_equals s[i++] 'S'
    expect_equals s[i++] 'ø'
    expect_equals s[i++] null
    expect_equals s[i++] 'e'
    expect_equals s[i++] 'n'
    expect_equals s[i++] ' '
    expect_equals s[i++] 's'
    expect_equals s[i++] 'å'
    expect_equals s[i++] null
    expect_equals s[i++] ' '
    expect_equals s[i++] 's'
    expect_equals s[i++] 'æ'
    expect_equals s[i++] null
    expect_equals s[i++] 'r'
    expect_equals s[i++] ' '
    expect_equals s[i++] 'u'
    expect_equals s[i++] 'd'
    expect_equals s[i++] '!'
    )
  test_soen.call str1 0
  for i := 0; i < big_repetitions; i++:
    test_soen.call long_str1 (i * str1.size)

  // Euro sign is a three byte UTF-8 sequence.
  s := "Only €2"  // Only two Euros.
  i := 0
  expect_equals s[i++] 'O'
  expect_equals s[i++] 'n'
  expect_equals s[i++] 'l'
  expect_equals s[i++] 'y'
  expect_equals s[i++] ' '
  expect_equals s[i++] '€'
  expect_equals s[i++] null
  expect_equals s[i++] null
  expect_equals s[i++] '2'
  expect_out_of_bounds: s[i]
  expect_equals s s.to_byte_array.to_string

  // Some emoji like flags consist of more than one Unicode code point, where
  // each code point is a 4-byte UTF-8 sequence.
  s = "🇪🇺"  // EU flag.
  i = 0
  expect_equals s[i++] '🇪'
  expect_equals s[i++] null
  expect_equals s[i++] null
  expect_equals s[i++] null
  expect_equals s[i++] '🇺'
  expect_equals s[i++] null
  expect_equals s[i++] null
  expect_equals s[i++] null
  expect_out_of_bounds: s[i]
  expect_equals s s.to_byte_array.to_string

  denmark := "🇩🇰"
  sweden := "🇸🇪"
  germany := (denmark.copy 0 4) + (sweden.copy 4 8)
  expect_equals germany "🇩🇪"
  i = 0
  expect_equals germany[i++] '🇩'
  expect_equals germany[i++] null
  expect_equals germany[i++] null
  expect_equals germany[i++] null
  expect_equals germany[i++] '🇪'
  expect_equals germany[i++] null
  expect_equals germany[i++] null
  expect_equals germany[i++] null
  expect_out_of_bounds: germany[i]
  expect_equals germany germany.to_byte_array.to_string

  for x := 0; x < germany.size; x++:
    for y := x; y <= germany.size; y++:
      ok := false
      // Zero length slices between the letters are OK
      if x == 0 and y == 0: ok = true
      if x == 4 and y == 4: ok = true
      if x == 8 and y == 8: ok = true
      // From the start to the end of the D or the end of the string is OK.
      if x == 0 and (y == 4 or y == 8): ok = true
      // From the start of the E to the end is OK.
      if x == 4 and y == 8: ok = true
      if ok:
        expect_equals (germany.copy x y).size (y - x)
      else:
        expect_illegal_utf_8: germany.copy x y

  for x := 0; x < germany.size; x++:
    for y := x; y <= germany.size; y++:
      copied := germany.copy --force_valid x y
      if x == y: expect_equals 0 copied.size
      adjust := ::
        // From the start to the end of the D.
        if      0 <= it < 4: 0
        // From the D to the E
        else if 4 <= it < 8: 4
        else:                8  // The end of the string.

      adjusted_x := adjust.call x
      adjusted_y := adjust.call y

      if adjusted_x == adjusted_y:                 expect_equals "" copied
      else if adjusted_x == 0 and adjusted_y == 4: expect_equals "🇩" copied
      else if adjusted_x == 0 and adjusted_y == 8: expect_equals "🇩🇪" copied
      else if adjusted_x == 4 and adjusted_y == 8: expect_equals "🇪" copied
      else: throw "bad string"

  // Combining accent, followed by letter.  These stay as two Unicode code
  // points and are not normalized to one code point by string concatenation.
  ahe := "Ah´" + "e"
  i = 0
  expect_equals ahe[i++] 'A'
  expect_equals ahe[i++] 'h'
  expect_equals ahe[i++] '´'
  expect_equals ahe[i++] null
  expect_equals ahe[i++] 'e'
  expect_out_of_bounds: ahe[i]
  expect_equals ahe ahe.to_byte_array.to_string

test_slice_string_at:
  REPETITIONS ::= 3
  short := "Søen så sær ud!"
  str1 := short * REPETITIONS
  slice := "-$str1"[1..]
  expect slice is StringSlice_

  expect_equals str1 slice.to_byte_array.to_string
  expect_out_of_bounds: slice[str1.size]
  test_soen := (: |s offset|
    i := offset
    expect_equals s[i++] 'S'
    expect_equals s[i++] 'ø'
    expect_equals s[i++] null
    expect_equals s[i++] 'e'
    expect_equals s[i++] 'n'
    expect_equals s[i++] ' '
    expect_equals s[i++] 's'
    expect_equals s[i++] 'å'
    expect_equals s[i++] null
    expect_equals s[i++] ' '
    expect_equals s[i++] 's'
    expect_equals s[i++] 'æ'
    expect_equals s[i++] null
    expect_equals s[i++] 'r'
    expect_equals s[i++] ' '
    expect_equals s[i++] 'u'
    expect_equals s[i++] 'd'
    expect_equals s[i++] '!'
    )
  for i := 0; i < REPETITIONS; i++:
    test_soen.call slice (i * short.size)

test_write_to_byte_array:
  expect_equals 1 (utf_8_bytes 0)
  expect_equals 1 (utf_8_bytes 0x7f)
  expect_equals 2 (utf_8_bytes 0x80)
  expect_equals 2 (utf_8_bytes 0x7ff)
  expect_equals 3 (utf_8_bytes 0x800)
  expect_equals 3 (utf_8_bytes 0xffff)
  expect_equals 4 (utf_8_bytes 0x10000)
  expect_equals 4 (utf_8_bytes 0x10ffff)

  check_copy := : | bytes offset |
    bytes.size.repeat:
      if it == offset + 0: expect_equals 'S' bytes[it]
      else if it == offset + 1: expect_equals 0b1100_0011 bytes[it]
      else if it == offset + 2: expect_equals 0b1011_1000 bytes[it]
      else if it == offset + 3: expect_equals 'e' bytes[it]
      else if it == offset + 4: expect_equals 'n' bytes[it]
      else: expect_equals 0 bytes[it]

  str := "Søen"
  bytes := ByteArray str.size
  str.write_to_byte_array bytes
  check_copy.call bytes 0

  bytes = ByteArray 2 * str.size
  str.write_to_byte_array bytes 5
  check_copy.call bytes 5

  bytes = ByteArray 2 * str.size
  str.write_to_byte_array bytes 1 4 5
  // Add the missing 'S' and 'n' so we can use our copy-check function.
  expect_equals 0 bytes[4]
  bytes[4] = 'S'
  expect_equals 0 bytes[8]
  bytes[8] = 'n'
  check_copy.call bytes 4

test_slice_write_to_byte_array:
  str := "In ancient times cats were worshipped as gods; they have not forgotten this."

  check_copy := : | bytes offset |
    bytes.size.repeat:
      if offset <= it < offset + str.size:
        expect_equals str[it - offset] bytes[it]
      else:
        expect_equals 0 bytes[it]

  slice := "-$str"[1..]
  expect slice is StringSlice_
  bytes := ByteArray slice.size
  str.write_to_byte_array bytes
  check_copy.call bytes 0

  bytes = ByteArray 2 * str.size
  str.write_to_byte_array bytes 5
  check_copy.call bytes 5

  bytes = ByteArray 10
  str.write_to_byte_array bytes 17 21 5
  expect_equals 'c' bytes[5]
  expect_equals 'a' bytes[6]
  expect_equals 't' bytes[7]
  expect_equals 's' bytes[8]
  bytes[5..9].fill 0
  bytes.do: expect_equals 0 it

test_trim:
  expect_equals "foo" "foo"
  expect_equals "foo" " foo".trim
  expect_equals "foo" " foo ".trim
  expect_equals "foo" "    foo    ".trim
  expect_equals "foo" ("  " * 1000 + "foo" + "  " * 1000).trim
  expect_equals "" "".trim
  expect_equals "" " ".trim
  expect_equals "" "  ".trim

  expect_equals "foo" ("foo".trim --left)
  expect_equals "foo" ("foo".trim --right)
  expect_equals "foo" (" foo".trim --left)
  expect_equals "foo" ("foo ".trim --right)
  expect_equals "foo " (" foo ".trim --left)
  expect_equals " foo" (" foo ".trim --right)
  expect_equals "foo    " ("    foo    ".trim --left)
  expect_equals "    foo" ("    foo    ".trim --right)
  expect_equals "" ("".trim --left)
  expect_equals "" (" ".trim --left)
  expect_equals "" ("  ".trim --left)
  expect_equals "" ("".trim --right)
  expect_equals "" (" ".trim --right)
  expect_equals "" ("  ".trim --right)

  expect_equals "www.example.com" ("http://www.example.com".trim --left "http://")
  str := "foobar"
  expect_equals "bar" (str.trim --left "foo")
  expect_equals "foobar" (str.trim --left "")
  expect_equals "foobar" (str.trim --left "bar")
  expect_equals "foobar" (str.trim --left "gee")
  expect_equals "NO_PREFIX" (str.trim --left "bar" --if_absent=: "NO_PREFIX")
  expect_equals "NO_PREFIX" (str.trim --left "gee" --if_absent=: "NO_PREFIX")

  str = "barfoo"
  expect_equals "foo" ("foo.toit".trim --right ".toit")
  expect_equals "bar" (str.trim --right "foo")
  expect_equals "barfoo" (str.trim --right "")
  expect_equals "barfoo" (str.trim --right "bar")
  expect_equals "barfoo" (str.trim --right "gee")
  expect_equals "NO_PREFIX" (str.trim --right "bar" --if_absent=: "NO_PREFIX")
  expect_equals "NO_PREFIX" (str.trim --right "gee" --if_absent=: "NO_PREFIX")

  unicode_whitespace_runes := [
    0x0009, 0x000A, 0x000B, 0x000C, 0x000D,  // White_Space # Cc   <control-0009>..<control-000D>
    0x0020,                                  // White_Space # Zs   SPACE
    0x0085,                                  // White_Space # Cc   <control-0085>
    0x00A0,                                  // White_Space # Zs   NO-BREAK SPACE
    0x1680,                                  // White_Space # Zs   OGHAM SPACE MARK
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
      0x2005, 0x2006, 0x2007, 0x2008,
      0x2009, 0x200A,                        // White_Space # Zs   EN QUAD..HAIR SPACE
    0x2028,                                  // White_Space # Zl   LINE SEPARATOR
    0x2029,                                  // White_Space # Zp   PARAGRAPH SEPARATOR
    0x202F,                                  // White_Space # Zs   NARROW NO-BREAK SPACE
    0x205F,                                  // White_Space # Zs   MEDIUM MATHEMATICAL SPACE
    0x3000,                                  // White_Space # Zs   IDEOGRAPHIC SPACE

    0xFEFF,
  ]

  unicode_whitespaces := unicode_whitespace_runes.map: string.from_rune it
  unicode_whitespaces.do:
    expected := "🙈foo🙈"
    prefixed := it + expected
    suffixed := expected + it
    surrounded := it + expected + it
    expect_equals expected prefixed.trim
    expect_equals expected suffixed.trim
    expect_equals expected surrounded.trim
    expect_equals expected (prefixed.trim --left)
    expect_equals expected (suffixed.trim --right)

test_compare_to:
  expect_equals -1 ("a".compare_to "b")
  expect_equals 0 ("a".compare_to "a")
  expect_equals 1 ("b".compare_to "a")
  expect_equals -1 ("ab".compare_to "abc")
  expect_equals 1 ("abc".compare_to "ab")
  expect_equals 1 ("Amélie".compare_to "Amelie")
  expect_equals 1 ("Amélie".compare_to "Amzlie")

  expect_equals -1 ("a".compare_to "a" --if_equal=: -1)
  expect_equals 0 ("a".compare_to "a" --if_equal=: 0)
  expect_equals 1 ("a".compare_to "a" --if_equal=: 1)
  expect_equals
      1
      "a".compare_to "a" --if_equal=:
        "b".compare_to "b" --if_equal=:
          "c".compare_to "c" --if_equal=:
            "z".compare_to "a"
  big_a := "foo" * 1000 + "a"
  big_b := "foo" * 1000 + "b"
  big_c := "foo" * 1000 + "c"
  big_z := "foo" * 1000 + "z"
  expect_equals
      1
      big_a.compare_to big_a --if_equal=:
        big_b.compare_to big_b --if_equal=:
          big_c.compare_to big_c --if_equal=:
            big_z.compare_to big_a

test_slice_compare_to:
  str := "Five exclamation marks, the sure sign of an insane mind."
  slice_a := "-a $str"[1..]
  slice_b := "-b $str"[1..]

  expect_equals -1 (slice_a.compare_to slice_b)
  expect_equals -1 (slice_a.copy.compare_to slice_b)
  expect_equals -1 (slice_a.compare_to slice_b.copy)
  expect_equals 1 (slice_b.compare_to slice_a)
  expect_equals 1 (slice_b.copy.compare_to slice_a)
  expect_equals 1 (slice_b.compare_to slice_a.copy)
  expect_equals 0 (slice_a.compare_to slice_a)
  expect_equals 0 (slice_a.copy.compare_to slice_a)
  expect_equals 0 (slice_a.compare_to slice_a.copy)

test_pad:
  str := "foo"
  expect_equals "  foo" (str.pad --left 5)
  expect_equals "00foo" (str.pad --left 5 '0')

  expect_equals "foo" (str.pad --left 3)
  expect_equals "foo" (str.pad --left 1)
  expect_equals "foo" (str.pad --left -1)

  expect_equals "  foo" (str.pad 5)
  expect_equals "00foo" (str.pad 5 '0')

  expect_equals "foo" (str.pad 3)
  expect_equals "foo" (str.pad 1)
  expect_equals "foo" (str.pad -1)

  expect_equals "foo  " (str.pad --right 5)
  expect_equals "foo00" (str.pad --right 5 '0')

  expect_equals "foo" (str.pad --right 3)
  expect_equals "foo" (str.pad --right 1)
  expect_equals "foo" (str.pad --right -1)

  expect_equals " foo " (str.pad --center 5)
  expect_equals "0foo0" (str.pad --center 5 '0')

  expect_equals " foo  " (str.pad --center 6)
  expect_equals "0foo00" (str.pad --center 6 '0')

  expect_equals "foo" (str.pad --center 3)
  expect_equals "foo" (str.pad --center 1)
  expect_equals "foo" (str.pad --center -1)

  left_pad_big := str.pad 2000
  expect_equals 2000 left_pad_big.size
  expect_equals ' ' left_pad_big[0]
  expect_equals 'o' left_pad_big[1999]

  center_pad_big := str.pad --center 2000
  expect_equals 2000 center_pad_big.size
  expect_equals ' ' center_pad_big[0]
  expect_equals ' ' center_pad_big[199]
  expect_equals "foo" center_pad_big.trim

  right_pad_big := str.pad --right 2000
  expect_equals 2000 right_pad_big.size
  expect_equals 'f' right_pad_big[0]
  expect_equals ' ' right_pad_big[1999]

test_multiply:
  expect_equals "" ("" * 0)
  expect_equals "" ("" * 1)
  expect_equals "" ("" * 3)
  expect_equals "" ("a" * 0)
  expect_equals "a" ("a" * 1)
  expect_equals "aaa" ("a" * 3)
  expect_equals "" ("foo" * 0)
  expect_equals "foo" ("foo" * 1)
  expect_equals "foofoofoo" ("foo" * 3)
  expect_equals "     " (" " * 5)

  big := "abc" * 1000
  expect_equals 3000 big.size
  j := 0
  1000.repeat:
    expect_equals 'a' big[j++]
    expect_equals 'b' big[j++]
    expect_equals 'c' big[j++]

test_slice_multiply:
  str := "Coming back to where you started is not the same as never leaving."
  slice := "-$str"[1..]
  expect slice is StringSlice_

  double := slice * 2
  expect double is String_
  expect_equals (str * 2) double

test_index_of:
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of "so" -1 --if_absent=: throw "NOT_FOUND"
  expect_equals 3 ("Bonsoir".index_of "so" 0 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 ("Bonsoir".index_of "so" 1 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 ("Bonsoir".index_of "so" 2 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 ("Bonsoir".index_of "so" 3 --if_absent=: throw "NOT_FOUND")
  expect_equals 42 ("Bonsoir".index_of "so" 4 --if_absent=: 42)
  expect_equals 42 ("Bonsoir".index_of "so" 5 --if_absent=: 42)
  expect_equals 42 ("Bonsoir".index_of "so" 6 --if_absent=: 42)
  expect_equals 42 ("Bonsoir".index_of "so" 7 --if_absent=: 42)
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of "so" 8 --if_absent=: 42

  expect_equals 3 ("Bonsoir".index_of "soir" 0 --if_absent=: throw "NOT_FOUND")

  expect_error "BAD ARGUMENTS": "Bonsoir".index_of "" -1 --if_absent=: throw "NOT_FOUND"
  expect_equals 0 ("Bonsoir".index_of "" 0 --if_absent=: throw "NOT_FOUND")
  expect_equals 1 ("Bonsoir".index_of "" 1 --if_absent=: throw "NOT_FOUND")
  expect_equals 7 ("Bonsoir".index_of "" 7 --if_absent=: throw "NOT_FOUND")
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of "" 8 --if_absent=: 42
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of "" 6 5 --if_absent=: 42
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of "" 9 9 --if_absent=: 42
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of "" 8 8 --if_absent=: 42
  expect_equals 7 ("Bonsoir".index_of "" 7 7 --if_absent=: 42)
  expect_equals 6 ("Bonsoir".index_of "" 6 6 --if_absent=: 42)
  expect_equals 0 ("".index_of "" --if_absent=: throw "NOT FOUND")

  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" 0 8 --if_absent=: throw "NOT_FOUND"
  expect_equals 3 ("Bonsoir".index_of --last "so" 0 7 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 ("Bonsoir".index_of --last "so" 0 6 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 ("Bonsoir".index_of --last "so" 0 5 --if_absent=: throw "NOT_FOUND")
  expect_equals 42 ("Bonsoir".index_of --last "so" 0 4 --if_absent=: 42)
  expect_equals 42 ("Bonsoir".index_of --last "so" 0 3 --if_absent=: 42)
  expect_equals 42 ("Bonsoir".index_of --last "so" 0 2 --if_absent=: 42)
  expect_equals 42 ("Bonsoir".index_of --last "so" 0 1 --if_absent=: 42)
  expect_equals 42 ("Bonsoir".index_of --last "so" 0 0 --if_absent=: 42)

  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" -1 8 --if_absent=: throw "NOT_FOUND"
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" -1 7 --if_absent=: throw "NOT_FOUND"
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" -1 6 --if_absent=: throw "NOT_FOUND"
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" -1 5 --if_absent=: throw "NOT_FOUND"
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" -1 4 --if_absent=: 42
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" -1 3 --if_absent=: 42
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" -1 2 --if_absent=: 42
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" -1 1 --if_absent=: 42
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "so" -1 0 --if_absent=: 42

  expect_equals 3 ("Bonsoir".index_of --last "soir" 0 7 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 ("Bonsoir".index_of --last "soir" 1 7 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 ("Bonsoir".index_of --last "soir" 2 7 --if_absent=: throw "NOT_FOUND")

  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "" 0 8 --if_absent=: throw "NOT_FOUND"
  expect_equals 7 ("Bonsoir".index_of --last "" 0 7 --if_absent=: throw "NOT_FOUND")
  expect_equals 1 ("Bonsoir".index_of --last "" 0 1 --if_absent=: throw "NOT_FOUND")
  expect_equals 0 ("Bonsoir".index_of --last "" 0 0 --if_absent=: throw "NOT_FOUND")
  expect_error "BAD ARGUMENTS": "Bonsoir".index_of --last "" 0 -1 --if_absent=: 42
  expect_error "BAD ARGUMENTS": ("Bonsoir".index_of --last "" -1 8 --if_absent=: throw "NOT_FOUND")
  expect_error "BAD ARGUMENTS": ("Bonsoir".index_of --last "" -1 7 --if_absent=: throw "NOT_FOUND")
  expect_error "BAD ARGUMENTS": ("Bonsoir".index_of --last "" -1 1 --if_absent=: throw "NOT_FOUND")
  expect_error "BAD ARGUMENTS": ("Bonsoir".index_of --last "" -1 0 --if_absent=: throw "NOT_FOUND")
  expect_error "BAD ARGUMENTS": ("Bonsoir".index_of --last "" -1 -1 --if_absent=: 42)

  expect_equals 0 ("foobar".index_of "foo")
  expect_equals 3 ("foobar".index_of "bar")
  expect_equals -1 ("foo".index_of "bar")

  expect_equals 0 ("foobarfoo".index_of "foo")
  expect_equals 6 ("foobarfoo".index_of "foo" 1)
  expect_equals -1 ("foobarfoo".index_of "foo" 1 8)

  expect_error "BAD ARGUMENTS": "foobarfoo".index_of "foo" -1 999
  expect_error "BAD ARGUMENTS": "foobarfoo".index_of "foo" 1 999

  expect_equals 0 ("".index_of "" 0 0)
  expect_error "BAD ARGUMENTS": "".index_of "" -3 -3
  expect_error "BAD ARGUMENTS": "".index_of "" 2 2

  expect_equals 6 ("foobarfoo".index_of --last "foo")
  expect_equals 6 ("foobarfoo".index_of --last "foo" 1)
  expect_equals -1 ("foobarfoo".index_of --last "foo" 1 6)
  expect_equals 0 ("foobarfoo".index_of --last "foo" 0 8)
  expect_equals 0 ("foobarfoo".index_of --last "foo" 0 5)
  expect_equals 0 ("foobarfoo".index_of --last "foo" 0 8)

  expect_equals -1 ("foobarfoo".index_of --last "gee")
  expect_equals -1 ("foobarfoo".index_of --last "foo" 1 5)
  expect_equals 0  ("foobarfoo".index_of --last "foo" 0 8)

  expect_equals 3   ("foo".index_of "bar" --if_absent=: it.size)
  expect_equals 499 ("foobarfoo".index_of "foo" 1 8 --if_absent=: 499)
  expect_error "BAD ARGUMENTS": "".index_of "" 2 2 --if_absent=: -1
  expect_equals 42 ("foobarfoo".index_of "foo" 1 8 --if_absent=: 42)

  big_string := "Bonsoir" * 1000
  expect_error "BAD ARGUMENTS": big_string.index_of "so" -1 --if_absent=: throw "NOT_FOUND"
  expect_equals 3 (big_string.index_of "so" 0 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 (big_string.index_of "so" 1 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 (big_string.index_of "so" 2 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 (big_string.index_of "so" 3 --if_absent=: throw "NOT_FOUND")
  expect_equals 10 (big_string.index_of "so" 4 --if_absent=: throw "NOT_FOUND")
  expect_equals (7 * 999 + 3) (big_string.index_of "so" (7*999) --if_absent=: throw "NOT_FOUND")

test_slice_index_of:
  str := "Bonsoir - In the beginning there was nothing, which exploded."
  slice := "-$str"[1..]
  expect_error "BAD ARGUMENTS": slice.index_of "so" -1 --if_absent=: throw "NOT_FOUND"
  expect_equals 3 (slice.index_of "so" 0 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 (slice.index_of "so" 1 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 (slice.index_of "so" 2 --if_absent=: throw "NOT_FOUND")
  expect_equals 3 (slice.index_of "so" 3 --if_absent=: throw "NOT_FOUND")
  expect_equals 42 (slice.index_of "so" 4 --if_absent=: 42)
  expect_equals 42 (slice.index_of "so" slice.size --if_absent=: 42)
  expect_error "BAD ARGUMENTS": slice.index_of "so" (slice.size + 1) --if_absent=: 42

test_contains:
  expect_error "BAD ARGUMENTS": "Bonsoir".contains "so" -1
  expect ("Bonsoir".contains "so" 0)
  expect ("Bonsoir".contains "so" 1)
  expect ("Bonsoir".contains "so" 2)
  expect ("Bonsoir".contains "so" 3)
  expect (not "Bonsoir".contains "so" 4)
  expect (not "Bonsoir".contains "so" 5)
  expect (not "Bonsoir".contains "so" 6)
  expect (not "Bonsoir".contains "so" 7)
  expect_error "BAD ARGUMENTS": "Bonsoir".contains "so" 8

  expect ("Bonsoir".contains "soir" 0)

  expect_error "BAD ARGUMENTS": "Bonsoir".contains "" -1
  expect ("Bonsoir".contains "" 0)
  expect ("Bonsoir".contains "" 1)
  expect ("Bonsoir".contains "" 7)
  expect_error "BAD ARGUMENTS": "Bonsoir".contains "" 8
  expect_error "BAD ARGUMENTS": "Bonsoir".contains "" 6 5
  expect_error "BAD ARGUMENTS": "Bonsoir".contains "" 9 9
  expect_error "BAD ARGUMENTS": "Bonsoir".contains "" 8 8
  expect ("Bonsoir".contains "" 7 7)
  expect ("Bonsoir".contains "" 6 6)
  expect ("".contains "")

  expect ("foobar".contains "foo")
  expect ("foobar".contains "bar")
  expect (not "foo".contains "bar")

  expect ("foobarfoo".contains "foo")
  expect ("foobarfoo".contains "foo" 1)
  expect (not "foobarfoo".contains "foo" 1 8)

  expect_error "BAD ARGUMENTS": "foobarfoo".contains "foo" -1 999
  expect_error "BAD ARGUMENTS": "foobarfoo".contains "foo" 1 999

  expect ("".contains "" 0 0)
  expect_error "BAD ARGUMENTS": "".contains "" -3 -3
  expect_error "BAD ARGUMENTS": "".contains "" 2 2

  expect (not "foo".contains "bar")
  expect (not "foobarfoo".contains "foo" 1 8 )
  expect_error "BAD ARGUMENTS": "".contains "" 2 2
  expect (not "foobarfoo".contains "foo" 1 8)

  short_string := "Bonsoir Madame"
  big_string := short_string * 500
  expect (big_string.contains "soir")
  expect (big_string.contains "soir" 7)
  expect (big_string.contains "soir" (7 * 499))
  expect (not big_string.contains "soir" (short_string.size * 499 + 4))
  expect (not big_string.contains "soir" 4 12)

// TODO(florian): move this function to the top.
main:
  test_interpolation
  test_matches
  test_glob
  test_starts_with
  test_ends_with
  test_copy
  test_escaped_characters
  test_conversion_from_byte_array
  test_string_at
  test_write_to_byte_array
  test_split
  test_multiline
  test_trim
  test_compare_to
  test_pad
  test_multiply
  test_do
  test_size
  test_is_empty
  test_at
  test_from_rune
  test_index_of
  test_contains
  test_replace

  test_identical

  test_slice
  test_slice_matches
  test_slice_starts_with
  test_slice_copy
  test_slice_string_at
  test_slice_write_to_byte_array
  test_slice_compare_to
  test_slice_multiply
  test_slice_at
  test_slice_index_of
  test_slice_replace

  test_hash_code

  test_substitute

  expect "fisk".size == 4 --message="string size test"
  expect ("A"[0]) == 'A' --message="string at test"
  expect ("fisk" + "fugl").size == 8

  expect_wrong_object_type:
    x := null
    x = "foo"
    x + 3

test_interpolation:
  x := 42
  expect_equals "x42" "x$(x)"
  expect_equals "x42" "x$x"
  expect_equals "x42y" "x$(x)y"

  xx := 87
  expect_equals "87" "$xx"
  expect_equals "87" "$(xx)"
  expect_equals " 87" " $xx"
  expect_equals " 87" " $(xx)"
  expect_equals " 87 " " $xx "
  expect_equals " 87 " " $(xx) "

  expect_equals "3" "$(1 + 2)"

  expect_equals "1234567890abcde" "1$("2" + "3$("4" + "5$("6" + "7$("8" + "9$("0")a")b")c")d")e"

  neg := -42
  expect_equals "42 -42. -42." "$neg.abs $neg. $neg."
  z := [1, -2, [3, -4]]
  expect_equals "1 -2 2 3 4 42 ["
                "$z[0] $z[1] $z[1].abs $z[2][0] $z[2][1].abs $x ["
  expect_equals "4242342442" "$x$neg.abs$z[2][0]$x$z[2][1].abs$x"

  expect_equals "42\""  "$x\""
  expect_equals "\"42\""  "\"$x\""
  expect_equals "\"\\" """"\\"""
  expect_equals " \"\"" """ "\""""
  expect_equals "42\"\\" """$x"\\"""
  expect_equals "42 \"\"" """$x "\""""
  expect_equals "\"42\"\\" """\"$x"\\"""
  expect_equals "\"42 \"\"" """\"$x "\""""

  // Interpolation with formatting
  xxx := 234.5455544454
  expect_equals "[         234.55         ]" "[$(%^24.2f xxx)]"

  a := A
  b := B
  expect_equals "A" a.stringify
  expect_equals "A:B" b.stringify

  slice := "12345678911234567892"[1..19]
  expect_equals "-234567891123456789-" "-$slice-"

test_identical:
  str := "Knuth"
  expect
    identical str str

  str2 := "Knu" + "th"
  expect
    identical str str2
  expect
    identical str2 str

  str3 := str + "enborg Safaripark"
  str4 := str2 + "enborg" + " Safaripark"

  expect
    identical str3 str4
  expect
    identical str4 str3

  expect_equals false
    identical str str4
  expect_equals false
    identical str2 str3

  expect_equals false
    identical "Knuth" "Knuþ"

  expect_equals false
    identical "knuth" "Knuth"

  with_null_1 := "knu\00th"
  with_null_2 := "knu\00þ"
  expect_equals with_null_1.size with_null_2.size
  expect_equals false
    identical with_null_1 with_null_2

  huge_1 := "0123456789" * 500            // 5k string will be external.
  huge_2 := "01234567890123456789" * 250  // 5k string will be external.
  expect_equals huge_1.size huge_2.size
  expect_equals true
    identical huge_1 huge_2

  huge_3 := "0123456789" * 499 + "x123456789"
  expect_equals huge_1.size huge_3.size
  expect_equals false
    identical huge_1 huge_3

test_slice:
  str := "XToad the Wet SprocketX"
  slice := str[1..]
  expect slice is StringSlice_
  expect_equals (str.size - 1) slice.size

  slice = str[..]
  expect slice is String_  // No slice as the original is returned.

  slice = str[1..4]
  expect slice is String_  // No slice as it's too small.

  slice = str[..str.size - 1]
  expect slice is StringSlice_
  expect_equals (str.size - 1) slice.size

  slice = str[1..str.size - 1]
  expect slice is StringSlice_
  expect_equals slice "Toad the Wet Sprocket"
  expect_equals (str.size - 2) slice.size

  slice2 := slice[..]
  expect (identical slice slice2)

  slice2 = slice[..4]
  expect_equals "Toad" slice2
  expect slice2 is String_  // Too short.

  slice2 = slice[..slice.size - 1]
  expect slice2 is StringSlice_
  expect_equals "Toad the Wet Sprocke" slice2

  soeen := "Søen så sær ud!"
  expect_error "ILLEGAL_UTF_8": soeen[2..]
  expect_error "ILLEGAL_UTF_8": soeen[2..2]
  // We are attempting to make a copy of the short string.
  expect_error "ILLEGAL_UTF_8": soeen[1..2]
  expect_error "ILLEGAL_UTF_8": (soeen + soeen)[1..(soeen.size + 2)]
  expect_error "ILLEGAL_UTF_8": (soeen + soeen)[..(soeen.size + 2)]
  expect_error "OUT_OF_BOUNDS": (soeen + soeen)[-1..]
  expect_error "OUT_OF_BOUNDS": (soeen + soeen)[..soeen.size * 2 + 1]

  slice = "-$soeen"[1..]
  expect_error "ILLEGAL_UTF_8": slice[2..]
  // We are attempting to make a copy of the short string.
  expect_error "ILLEGAL_UTF_8": slice[1..2]
  slice = "-$soeen$soeen"[1..]
  expect_error "ILLEGAL_UTF_8": slice[1..(soeen.size + 2)]
  expect_error "ILLEGAL_UTF_8": slice[..(soeen.size + 2)]
  expect_error "OUT_OF_BOUNDS": slice[-1..]
  expect_error "OUT_OF_BOUNDS": slice[..soeen.size * 2 + 1]
  expect_error "OUT_OF_BOUNDS": slice[..soeen.size * 2 + 1]

test_matches:
  expect (not "Toad the Wet Sprocket".matches "Toad" --at=-1) --message="No match before start"
  expect (not "Toad the Wet Sprocket".matches "Toad" --at=1) --message="No match at 1"
  expect (not "Toad the Wet Sprocket".matches "Sprocket" --at=12) --message="No match at 12"
  expect ("Toad the Wet Sprocket".matches "Sprocket" --at=13) --message="Match at end"
  expect (not "Toad the Wet Sprocket".matches "Sprocket" --at=14) --message="No match past end"

  big_string := "Toad" * 1000
  expect (big_string.matches "Toad" --at=0)
  expect (not big_string.matches "Toad" --at=1)
  expect (big_string.matches "Toad" --at=(4000 - 4))
  expect (not big_string.matches "Toad" --at=(4000 - 3))

test_slice_matches:
  expect "XToad the Wet Sprocket"[1..] is StringSlice_
  expect (not "XToad the Wet Sprocket"[1..].matches "Toad" --at=-1)
  expect ("XToad the Wet Sprocket"[1..].matches "Sprocket" --at=13)

  expect "Toad the Wet Sprocket"[1..] is StringSlice_
  expect ("Toad the Wet Sprocket".matches "Toad the Wet Sprocket"[1..] --at=1)

test_glob:
  expect ("kÆlle".glob "kÆlle")
  expect ("kÆlle".glob "kÆll?")
  expect ("kÆlle".glob "kÆl?e")
  expect ("kÆlle".glob "kÆ?le")
  expect ("kÆlle".glob "k?lle")
  expect ("kÆlle".glob "?Ælle")
  expect ("kallÆ".glob "k*Æ")
  expect ("kallÆ".glob "*Æ")
  expect ("kalle".glob "k*")
  expect ("kall*".glob "kall\\*")
  expect (not "kalle".glob "kall\\*")
  expect ("kall?".glob "kall\\?")
  expect (not  "kalle".glob "kall\\?")
  expect ("ka?le".glob "ka\\?le")
  expect (not "kalle".glob "ka\\?le")
  expect ("ka\\le".glob "ka\\\\le")
  expect ("ka\\le".glob "ka\\\\le")

test_starts_with:
  expect ("Toad the Wet Sprocket".starts_with "Toad") --message="Match at 0"
  expect (not "Toad the Wet Sprocket".starts_with "Wet")

  big_string := "Toad" * 1000
  expect (big_string.starts_with "Toad")
  expect (not big_string.starts_with "Wet")

test_slice_starts_with:
  slice := "XToad the Wet Sprocket"[1..]
  expect slice is StringSlice_
  expect (slice.starts_with "Toad")
  expect (slice.starts_with slice)
  expect ("Toad the Wet Sprocket 123".starts_with slice)

test_ends_with:
  expect ("Toad the Wet Sprocket".ends_with "Sprocket") --message="Match at end"
  expect ("Toad the Wet Sprocket".ends_with "procket") --message="Match at end"
  expect (not "Toad".ends_with "Sprocket") --message="No match at end"
  expect (not "Toad".ends_with "toad") --message="No match at end"

  big_string := "Toad the Wet" * 500
  expect (big_string.ends_with "Wet")
  expect (not big_string.ends_with "the")
  expect (not big_string.ends_with "XXX")

test_copy:
  expect_equals ("Ostesnaps".copy 0 9) "Ostesnaps"
  expect_equals ("Ostesnaps".copy 0 3) "Ost"
  expect_equals ("Ostesnaps".copy 4 9) "snaps"
  expect_equals ("Ostesnaps".copy 2 8) "tesnap"
  expect_out_of_bounds: "Ostesnaps".copy -1 3
  expect_out_of_bounds: "Ostesnaps".copy 0 10
  expect_out_of_bounds: "Ostesnaps".copy 1 10

  big_string := "Ostesnaps" * 500
  len := "Ostesnaps".size
  expect_equals (big_string.copy 0 3) "Ost"
  expect_equals (big_string.copy 4 9) "snaps"
  expect_equals (big_string.copy 2 8) "tesnap"
  expect_equals (big_string.copy (len * 300 + 0) (len * 300 + 3)) "Ost"
  expect_equals (big_string.copy (len * 300 + 4) (len * 300 + 9)) "snaps"
  expect_equals (big_string.copy (len * 300 + 2) (len * 300 + 8)) "tesnap"
  expect_equals (big_string.copy (len * 499 + 0) (len * 499 + 3)) "Ost"
  expect_equals (big_string.copy (len * 499 + 4) (len * 499 + 9)) "snaps"
  expect_equals (big_string.copy (len * 499 + 2) (len * 499 + 8)) "tesnap"
  expect_out_of_bounds: big_string.copy -1 3
  expect_out_of_bounds: big_string.copy 0 (len * 500 + 1)
  expect_out_of_bounds: big_string.copy 1 (len * 500 + 10)

test_slice_copy:
  toad := "Toad the Wet Sprocket"
  str := "-$toad-"

  slice := str[1..]
  expect slice is StringSlice_
  copy := slice.copy
  expect copy is String_
  expect_equals "$toad-" copy

  slice2 := slice
  expect (identical slice slice2)

  slice = str[..str.size - 1]
  expect slice is StringSlice_
  copy = slice.copy
  expect copy is String_
  expect_equals "-$toad" copy

  slice = str[1..str.size - 1]
  expect slice is StringSlice_
  copy = slice.copy
  expect copy is String_
  expect_equals toad copy

  short := slice[..4]  // Automatically copied because it's short.
  expect short is String_
  expect_equals "Toad" short
  short = slice.copy 0 4
  expect short is String_
  expect_equals "Toad" short

  longer := slice[1..18]
  expect longer is StringSlice_
  expect_equals "oad the Wet Sproc" longer
  longer = slice.copy 1 18
  expect longer is String_
  expect_equals "oad the Wet Sproc" longer
  expect_equals 17 longer.size

split_case haystack needle expectation:
  i := 0
  haystack.split needle:
    expect_equals expectation[i++] it
  expect_equals expectation.size i

test_split:
  split_case "Toad the Wet Sprocket" "e" ["Toad th", " W", "t Sprock", "t"]
  split_case " the dust " " " ["", "the", "dust", ""]
  split_case "of Baja California" "water" ["of Baja California"]
  split_case "Søen så sær ud!" "" ["S", "ø", "e", "n", " ", "s", "å", " ", "s", "æ", "r", " ", "u", "d", "!"]
  // Split currently splits things that are rendered as one glyph if they are
  // separate code points.
  split_case "Flag🇩🇰" "" ["F", "l", "a", "g", "🇩", "🇰"]

  expect_equals ["Toad th", " W", "t Sprock", "t"] ("Toad the Wet Sprocket".split "e")
  expect_equals ["", "the", "dust", ""]            (" the dust ".split " ")
  expect_equals ["a", "b", "c"]                    ("abc".split  "")
  expect_equals ["",""]                            ("foo".split  "foo")
  expect_equals ["a",""]                           ("afoo".split "foo")
  expect_equals ["", "b"]                          ("foob".split "foo")
  expect_equals []                                 ("".split "")
  expect_equals ["€"]                              ("€".split "")
  expect_equals ["€", "1", ",", "2", "3"]          ("€1,23".split "")

  gadsby := "If youth, throughout all history, had had a champion to stand up for it;"
  expect_equals [gadsby] (gadsby.split "e")

  expect_equals ["Toad th", " Wet Sprocket"] ("Toad the Wet Sprocket".split --at_first "e")
  expect_equals ["", "the dust "]            (" the dust ".split            --at_first " ")
  expect_equals [gadsby]                     (gadsby.split                  --at_first "e")

  expect_equals ["a", "bc"]   ("abc".split   --at_first "")
  expect_equals ["€", ""]     ("€".split     --at_first "")
  expect_equals ["€", "1,23"] ("€1,23".split --at_first "")
  expect_equals ["", ""]      ("foo".split   --at_first "foo")
  expect_equals ["a", ""]     ("afoo".split  --at_first "foo")
  expect_equals ["", "b"]     ("foob".split  --at_first "foo")
  expect_invalid_argument:    ("".split      --at_first "")

  big_string := "Toad" * 1000
  expect_equals [big_string] (big_string.split "e")

  split_t := big_string.split "T"
  expect_equals 1001 split_t.size
  expect_equals "" split_t[0]
  1000.repeat: expect_equals "oad" split_t[it + 1]

test_multiline:
  expect_equals "foo" """foo"""
  expect_equals "foo\"bar" """foo"bar"""
  expect_equals "foo\nbar" """foo
bar"""
  expect_equals "foobar" """\
foo\
bar\
"""
  expect_equals "foo\nbar" """\
foo
bar\
"""

  x := 42
  expect_equals "x42" """x$(x)"""
  expect_equals "x42\n" """
x$(x)
"""
  expect_equals "x42" """x$x"""
  expect_equals "x42\n" """
x$x
"""
  expect_equals "x\n42\n" """x
$x
"""
  expect_equals "x42y\n" """
x$(x)y
"""

  expect_equals "x42\" " """x$x" """

  xx := 87
  expect_equals "87" """$xx"""
  expect_equals "87" """$(xx)"""
  expect_equals " 87" """ $xx"""
  expect_equals " 87" """ $(xx)"""
  expect_equals " 87 " """ $xx """
  expect_equals " 87 " """ $(xx) """

  expect_equals "3" """$(1 + 2)"""

  expect_equals "1234567890abcde" """1$("2" + """3$("4" + "5$("6" + """7$("8" + "9$("0")a")b""")c")d""")e"""
  expect_equals "1\n  2  3\n  4567890ab\n  cde" """1
  $("2" + """\
  3
  $("4" + "5$("6" + """7$("8" + "9$("0")a")b
  """)c")d""")e"""

  expect_equals " " """ """
  expect_equals "" """
  """
  expect_equals "" """
       """
  expect_equals "aaa" """
    aaa"""
  expect_equals "aaa\n" """
    aaa
    """
  expect_equals "  foo\n" """
    foo
  """

  expect_equals "" """
  $("")"""
  expect_equals "" """
       $("")"""
  expect_equals "aaa" """
    $("aaa")"""
  expect_equals "aaa\n" """
    $("aaa")
    """
  expect_equals "  foo\n" """
    $("foo")
  """

  expect_equals "foo\nbar" """  $("foo")
  bar"""

  expect_equals "  " """\s """
  expect_equals "  foo\n  bar\n" """
  \s foo
    bar
  """

  expect_equals "  foo\n  bar" """
  \s foo
    bar"""

  // The line after 'foo' is empty.
  expect_equals "foo\n\nbar\n" """
    foo

    bar
    """

  expect_equals "  foo\n\n  bar\n" """
  foo

  bar
"""

  expect_equals "foo bar gee" """
  foo $("bar") gee"""

  // Newlines inside string interpolations don't count for indentation.
  expect_equals "  x" """  $(
    "x")"""

class A:
  stringify:
    return "A"

class B extends A:
  stringify:
    return "$super:B"

test_do:
  accumulated := []
  "abc".do: accumulated.add it
  expect_equals ['a', 'b', 'c'] accumulated

  accumulated = []
  "Flag🇩🇰".do: accumulated.add it
  expect_equals ['F', 'l', 'a', 'g', '🇩', null, null, null, '🇰', null, null, null] accumulated

  accumulated = []
  "Flag🇩🇰".do --runes: accumulated.add it
  expect_equals ['F', 'l', 'a', 'g', '🇩', '🇰'] accumulated

  short := "Flag🇩🇰"
  big_string := short * 1000
  counter := 0
  big_string.do:
    expect_equals short[counter++ % short.size] it
  expect_equals (short.size * 1000) counter

  short_runes := []
  short.do --runes: short_runes.add it
  counter = 0
  big_string.do --runes:
    expect_equals short_runes[counter++ % short_runes.size] it
  expect_equals (short_runes.size * 1000) counter

test_size:
  expect_equals 0 "".size
  expect_equals 1 "a".size
  expect_equals 4 "🇩".size
  expect_equals 8 "🇩🇰".size

  expect_equals 0 ("".size --runes)
  expect_equals 1 ("a".size --runes)
  expect_equals 1 ("🇩".size --runes)
  expect_equals 2 ("🇩🇰".size --runes)

test_is_empty:
  expect "".is_empty
  expect (not "a".is_empty)
  expect ("foobar".copy 0 0).is_empty

  bytes := ByteArray 10000
  for i := 0; i < bytes.size; i++: bytes[i] = 'a'
  big_string := bytes.to_string
  expect (not big_string.is_empty)
  expect (big_string.copy 0 0).is_empty

test_at:
  flag_dk := "Flag🇩🇰"
  expect_equals 'F' flag_dk[0]
  expect_equals 'F' flag_dk[flag_dk.rune_index 0]
  expect_equals 'F' (flag_dk.at --raw 0)

  expect_equals '🇩' flag_dk[4]
  expect_equals '🇩' flag_dk[flag_dk.rune_index 4]
  expect_equals 0xf0 (flag_dk.at --raw 4)

  expect_equals null flag_dk[5]
  expect_equals '🇩' flag_dk[flag_dk.rune_index 5]
  expect_equals 0x9f (flag_dk.at --raw 5)

  big_string := flag_dk * 1000
  expect_equals 'F' big_string[0]
  expect_equals 'F' big_string[big_string.rune_index 0]
  expect_equals 'F' (big_string.at --raw 0)

  expect_equals '🇩' big_string[4]
  expect_equals '🇩' big_string[big_string.rune_index 4]
  expect_equals 0xf0 (big_string.at --raw 4)

  expect_equals null big_string[5]
  expect_equals '🇩' big_string[big_string.rune_index 5]
  expect_equals 0x9f (big_string.at --raw 5)

  expect_equals 'F' big_string[flag_dk.size * 999 + 0]
  expect_equals 'F' big_string[big_string.rune_index flag_dk.size * 999 + 0]
  expect_equals 'F' (big_string.at --raw flag_dk.size * 999 + 0)

  expect_equals '🇩' big_string[flag_dk.size * 999 + 4]
  expect_equals '🇩' big_string[big_string.rune_index flag_dk.size * 999 + 4]
  expect_equals 0xf0 (big_string.at --raw flag_dk.size * 999 + 4)

  expect_equals null big_string[flag_dk.size * 999 + 5]
  expect_equals '🇩' big_string[big_string.rune_index flag_dk.size * 999 + 5]
  expect_equals 0x9f (big_string.at --raw flag_dk.size * 999 + 5)

test_slice_at:
  str := "Flag🇩🇰 - Real stupidity beats artificial intelligence every time."
  slice := "-$str"[1..]
  expect slice is StringSlice_

  expect_equals 'F' slice[0]
  expect_equals 'F' slice[slice.rune_index 0]
  expect_equals 'F' (slice.at --raw 0)

  expect_equals '🇩' slice[4]
  expect_equals '🇩' slice[slice.rune_index 4]
  expect_equals 0xf0 (slice.at --raw 4)

  expect_equals null slice[5]
  expect_equals '🇩' slice[slice.rune_index 5]
  expect_equals 0x9f (slice.at --raw 5)

test_from_rune:
  rune := 0
  str := string.from_rune rune
  expect_equals "\0" str
  str = string.from_runes [rune]
  expect_equals "\0" str

  rune = 1
  str = string.from_rune rune
  expect_equals "\x01" str

  rune = 'a'
  str = string.from_rune rune
  expect_equals "a" str

  interesting_runes := [
    126,
    127,
    0x7FF - 1,
    0x7FF,
    0x7FF + 1,
    0xD800 - 1,
    0xDFFF + 1,
    0xFFFF - 1,
    0xFFFF,
    0xFFFF + 1,
    0x10FFFF - 1,
    0x10FFFF,
  ]
  interesting_runes.do:
    str = string.from_rune it
    expect_equals 1 (str.size --runes)
    expect_equals it str[0]

  str = string.from_runes interesting_runes
  expect_equals
    interesting_runes.size
    str.size --runes

  expect_invalid_argument:
    string.from_rune -1

  expect_invalid_argument:
    string.from_runes [-1]

  expect_invalid_argument:
    string.from_rune (0x10FFFF + 1)

  expect_invalid_argument:
    string.from_runes [0x10FFFF + 1]

  for rune = 0xD800; rune <= 0xDFFF; rune++:
    expect_invalid_argument:
      string.from_rune rune

  for rune = 0xD800; rune <= 0xDFFF; rune++:
    expect_invalid_argument:
      string.from_runes [rune]

test_replace:
  expect_equals "" ("".replace "not found" "foo")
  expect_equals "" ("foo".replace "foo" "")
  expect_equals "foobar" ("barbar".replace "bar" "foo")
  expect_equals "barfoo" ("barbar".replace "bar" "foo" 1)
  expect_equals "barfoo" ("barbar".replace "bar" "foo" 3)
  expect_equals "barbar" ("barbar".replace "bar" "foo" 1 5)

  call_counter := 0
  expect_equals
    ""
    "".replace "not found":
      call_counter++
      "foo"
  expect_equals 0 call_counter

  expect_equals
    ""
    "foo".replace "foo":
      expect_equals "foo" it
      call_counter++
      ""
  expect_equals 1 call_counter

  call_counter = 0
  expect_equals
    "foobar"
    "barbar".replace "bar":
      expect_equals "bar" it
      call_counter++
      "foo"
  expect_equals 1 call_counter

  call_counter = 0
  expect_equals
    "barfoo"
    "barbar".replace "bar" 1:
      expect_equals "bar" it
      call_counter++
      "foo"
  expect_equals 1 call_counter

  call_counter = 0
  expect_equals
    "barfoo"
    "barbar".replace "bar" 3:
      expect_equals "bar" it
      call_counter++
      "foo"
  expect_equals 1 call_counter

  call_counter = 0
  expect_equals
    "barbar"
    "barbar".replace "bar" 1 3:
      call_counter++
      "foo"
  expect_equals 0 call_counter

  expect_equals "" ("".replace --all "not found" "foo")
  expect_equals "" ("foofoo".replace --all "foo" "")
  expect_equals "x" ("fooxfoo".replace --all "foo" "")
  expect_equals "foofoofoo" ("barbarbar".replace --all "bar" "foo")
  expect_equals "barfoofoo" ("barbarbar".replace --all "bar" "foo" 1)
  expect_equals "barfoofoo" ("barbarbar".replace --all "bar" "foo" 3)
  expect_equals "barbarbar" ("barbarbar".replace --all "bar" "foo" 1 5)

  call_counter = 0
  expect_equals
      ""
      "".replace --all "not found":
        "foo$(call_counter++)"
  expect_equals 0 call_counter

  expect_equals
    ""
    "foofoo".replace --all "foo":
      expect_equals "foo" it
      call_counter++
      ""
  expect_equals 2 call_counter

  call_counter = 0
  expect_equals
    "x"
    "fooxfoo".replace --all "foo":
      expect_equals "foo" it
      call_counter++
      ""
  expect_equals 2 call_counter

  call_counter = 0
  expect_equals
    "foo0foo1foo2"
    "barbarbar".replace --all "bar":
      expect_equals "bar" it
      "foo$(call_counter++)"
  expect_equals 3 call_counter

  call_counter = 0
  expect_equals
    "barfoo0foo1"
    "barbarbar".replace --all "bar" 1:
      expect_equals "bar" it
      "foo$(call_counter++)"
  expect_equals 2 call_counter

  call_counter = 0
  expect_equals
    "barfoo0foo1"
    "barbarbar".replace --all "bar" 3:
      expect_equals "bar" it
      "foo$(call_counter++)"
  expect_equals 2 call_counter

  call_counter = 0
  expect_equals
    "barbarbar"
    "barbarbar".replace --all "bar" 1 5:
      call_counter++
      "foo"
  expect_equals 0 call_counter

test_slice_replace:
  str := "Time is a drug. Too much of it kills you."
  slice := "-$str"[1..]
  expect slice is StringSlice_

  replaced := slice.replace "not-there" "something_else"
  expect (identical slice replaced)

  replaced = slice.replace "Time " "Terry "
  expect replaced is String_
  expect (replaced.starts_with "Terry ")

  slice = "-$str"[1..]
  expect_equals
    str.replace --all "i" "X"
    slice.replace --all "i" "X"

test_hash_code:
  str := "Coffee is a way of stealing time that should by rights belong to your older self."

  hash1 := "".hash_code
  hash2 := "x"[0..0].hash_code
  expect_equals hash1 hash2  // Trivially true, as an empty hash returns the empty string.

  slice := "-$str"[1..]
  expect_equals str.hash_code slice.hash_code

  expect_not hash1 == slice.hash_code

test_substitute:
  MAP ::= {
    "variable": "fixed",
    "value": "cost",
  }
  result := "Replace {{variable}} with {{value}}".substitute: MAP[it]
  expect_equals "Replace fixed with cost" result

  result = "Replace {{variable}} with {{value}} trailing text".substitute: MAP[it]
  expect_equals "Replace fixed with cost trailing text" result

  result = "".substitute: MAP[it]
  expect_equals "" result

  result = "{{variable}}".substitute: MAP[it]
  expect_equals "fixed" result

  result = "42foobarfizz103".substitute --open="foo" --close="fizz": "BAR"
  expect_equals "42BAR103" result

  result = "{{variable}} is not variable".substitute: MAP[it]
  expect_equals "fixed is not variable" result

  // Check that we remember to stringify.
  "The time is {{time}} now.".substitute: Time.now.local
