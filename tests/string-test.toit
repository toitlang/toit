// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect-error name [code]:
  expect-equals
    name
    catch code

expect-out-of-bounds [code]:
  expect-error "OUT_OF_BOUNDS" code

expect-illegal-utf-8 [code]:
  expect-error "ILLEGAL_UTF_8" code

expect-invalid-argument [code]:
  expect-error "INVALID_ARGUMENT" code

expect-wrong-object-type [code]:
  exception-name := catch code
  expect
      exception-name == "WRONG_OBJECT_TYPE" or exception-name == "AS_CHECK_FAILED"

test-escaped-characters:
  expect-equals "\x00" "\0"
  expect-equals "\x07" "\a"
  expect-equals "\x08" "\b"
  expect-equals "\x0C" "\f"
  expect-equals "\x0A" "\n"
  expect-equals "\x0D" "\r"
  expect-equals "\x09" "\t"
  expect-equals "\x0B" "\v"
  expect-equals "\x24" "\$"
  expect-equals "\x5C" "\\"
  expect-equals "\x22" "\""
  expect-equals "" """\
"""

  expect-equals "\x00"[0] 0x0
  expect-equals "\x0A"[0] 0xa
  expect-equals "\x0F"[0] 0xf
  expect-equals "\x99"[0] 0x99
  expect-equals "\xaa"[0] 0xaa
  expect-equals "\xff"[0] 0xff
  expect-equals "Z\x00Z"[0] 'Z'
  expect-equals "Z\x00Z"[1] 0x0
  expect-equals "Z\x00Z"[2] 'Z'
  expect-equals "Z\x0AZ"[0] 'Z'
  expect-equals "Z\x0AZ"[1] 0xa
  expect-equals "Z\x0AZ"[2] 'Z'
  expect-equals "Z\x0FZ"[0] 'Z'
  expect-equals "Z\x0FZ"[1] 0xf
  expect-equals "Z\x0FZ"[2] 'Z'
  expect-equals "Z\x99Z"[0] 'Z'
  expect-equals "Z\x99Z"[1] 0x99
  expect-equals "Z\x99Z"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\xaaZ"[0] 'Z'
  expect-equals "Z\xaaZ"[1] 0xaa
  expect-equals "Z\xaaZ"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\xffZ"[0] 'Z'
  expect-equals "Z\xffZ"[1] 0xff
  expect-equals "Z\xffZ"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\u0060Z"[0] 'Z'
  expect-equals "Z\u0060Z"[1] 0x60
  expect-equals "Z\u0060Z"[2] 'Z'
  expect-equals "Z\u0099Z"[0] 'Z'
  expect-equals "Z\u0099Z"[1] 0x99
  expect-equals "Z\u0099Z"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\u0160Z"[0] 'Z'
  expect-equals "Z\u0160Z"[1] 0x160
  expect-equals "Z\u0160Z"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\u1160Z"[0] 'Z'
  expect-equals "Z\u1160Z"[1] 0x1160
  expect-equals "Z\u1160Z"[4] 'Z'  // The encoded character requires three bytes.

  expect-equals '\x00' 0x0
  expect-equals '\x0A' 0xa
  expect-equals '\x0F' 0xf
  expect-equals '\x99' 0x99
  expect-equals '\xaa' 0xaa
  expect-equals '\xff' 0xff

  expect-equals "\x{0}"[0] 0x0
  expect-equals "\x{A}"[0] 0xa
  expect-equals "\x{F}"[0] 0xf
  expect-equals "\x{9}9"[0] 0x9
  expect-equals "\x{99}"[0] 0x99
  expect-equals "\x{a}a"[0] 0xa
  expect-equals "\x{aa}"[0] 0xaa
  expect-equals "\x{ff}"[0] 0xff
  expect-equals "Z\x{0}Z"[0] 'Z'
  expect-equals "Z\x{0}Z"[1] 0x0
  expect-equals "Z\x{0}Z"[2] 'Z'
  expect-equals "Z\x{A}Z"[0] 'Z'
  expect-equals "Z\x{A}Z"[1] 0xa
  expect-equals "Z\x{A}Z"[2] 'Z'
  expect-equals "Z\x{F}Z"[0] 'Z'
  expect-equals "Z\x{F}Z"[1] 0xf
  expect-equals "Z\x{F}Z"[2] 'Z'
  expect-equals "Z\x{9}9"[0] 'Z'
  expect-equals "Z\x{9}9"[1] 0x9
  expect-equals "Z\x{9}9"[2] '9'
  expect-equals "Z\x{99}Z"[0] 'Z'
  expect-equals "Z\x{99}Z"[1] 0x99
  expect-equals "Z\x{99}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\x{a}a"[0] 'Z'
  expect-equals "Z\x{a}a"[1] 0xa
  expect-equals "Z\x{a}a"[2] 'a'
  expect-equals "Z\x{aa}Z"[0] 'Z'
  expect-equals "Z\x{aa}Z"[1] 0xaa
  expect-equals "Z\x{aa}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\x{ff}Z"[0] 'Z'
  expect-equals "Z\x{ff}Z"[1] 0xff
  expect-equals "Z\x{ff}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\u{000060}Z"[0] 'Z'
  expect-equals "Z\u{000060}Z"[1] 0x60
  expect-equals "Z\u{000060}Z"[2] 'Z'
  expect-equals "Z\u{000099}Z"[0] 'Z'
  expect-equals "Z\u{000099}Z"[1] 0x99
  expect-equals "Z\u{000099}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\u{000160}Z"[0] 'Z'
  expect-equals "Z\u{000160}Z"[1] 0x160
  expect-equals "Z\u{000160}Z"[3] 'Z'  // The encoded character requires two bytes.
  expect-equals "Z\u{001160}Z"[0] 'Z'
  expect-equals "Z\u{001160}Z"[1] 0x1160
  expect-equals "Z\u{001160}Z"[4] 'Z'  // The encoded character requires three bytes.
  expect-equals "Z\u{011160}Z"[0] 'Z'
  expect-equals "Z\u{011160}Z"[1] 0x11160
  expect-equals "Z\u{011160}Z"[5] 'Z'  // The encoded character requires four bytes.
  expect-equals "Z\u{10FFFF}Z"[0] 'Z'
  expect-equals "Z\u{10FFFF}Z"[1] 0x10FFFF
  expect-equals "Z\u{10FFFF}Z"[5] 'Z'  // The encoded character requires four bytes.

  expect-equals '\x{0}' 0x0
  expect-equals '\x{A}' 0xa
  expect-equals '\x{F}' 0xf
  expect-equals '\x{99}' 0x99
  expect-equals '\x{aa}' 0xaa
  expect-equals '\x{ff}' 0xff

  expect-equals '\u{1}' 0x1
  expect-equals '\u{12}' 0x12
  expect-equals '\u{123}' 0x123
  expect-equals '\u{1234}' 0x1234
  expect-equals '\u{12345}' 0x12345
  expect-equals '\u{10FFFF}' 0x10FFFF

  expect-equals '\u0001' 0x1
  expect-equals '\u0012' 0x12
  expect-equals '\u0123' 0x123
  expect-equals '\u1234' 0x1234

check-to-string bytes str:
  // The input is an array, because that's what we have literal syntax for, so
  // we need to convert to an array.
  byte-array := ByteArray bytes.size + 2
  i := 0
  byte-array[i++] = '_'
  bytes.do: byte-array[i++] = it
  byte-array[i++] = '_'
  expect-equals "_$(str)_" byte-array.to-string

  // Also check the reverse direction
  byte-array = ByteArray 30
  30.repeat: byte-array[it] = '*'

  write-utf-8-to-byte-array byte-array 2 str[0]
  expect-equals '*' byte-array[0]
  expect-equals '*' byte-array[1]
  expect-equals '*' byte-array[str.size + 2]
  i = 2
  bytes.do: expect-equals it byte-array[i++]

check-illegal-utf-8 bytes expectation = null:
  byte-array := ByteArray bytes.size: bytes[it]
  string-with-replacements := byte-array.to-string-non-throwing
  expect (string-with-replacements.index-of "\ufffd") != -1
  if expectation: expect-equals string-with-replacements expectation
  expect-illegal-utf-8: byte-array.to-string

test-conversion-from-byte-array:
  check-to-string [0] "\x00"
  check-to-string [65] "A"
  check-to-string [0xc3, 0xa6] "æ"                       // Ae ligature.
  check-to-string [0xd0, 0x90] "А"                       // Cyrillic capital A.
  check-to-string [0xdf, 0xb9] "߹"                       // N'Ko exclamation mark.
  check-to-string [0xe2, 0x82, 0xac] "€"                 // Euro sign.
  check-to-string [0xe2, 0x98, 0x83] "☃"                 // Snowman.
  check-to-string [0xf0, 0x9f, 0x99, 0x88] "🙈"          // See-no-evil monkey.
  check-illegal-utf-8 [244, 65, 48] "\uFFFDA0"           // Low continuation bytes.
  check-illegal-utf-8 [244, 244, 48] "\uFFFD0"           // High continuation bytes.
  check-illegal-utf-8 [48, 244] "0\uFFFD"                // Missing continuation bytes.
  continuations := List 10 --initial=0xbf
  continuations[0] = 0x80
  check-illegal-utf-8 continuations "\uFFFD"             // Unexpected continuation byte.
  continuations[0] = 0xf8
  check-illegal-utf-8 continuations "\uFFFD"             // 5-byte sequence.
  continuations[0] = 0xfc
  check-illegal-utf-8 continuations "\uFFFD"             // 6-byte sequence.
  continuations[0] = 0xfe
  check-illegal-utf-8 continuations "\uFFFD"             // 7-byte sequence.
  continuations[0] = 0xff
  check-illegal-utf-8 continuations "\uFFFD"             // 8-byte sequence.
  check-illegal-utf-8 [0xc0, 0xdc] "\uFFFD"              // Overlong encoding of backslash.
  check-illegal-utf-8 [0xc1, 0xdf] "\uFFFD"              // Overlong encoding of DEL.
  check-illegal-utf-8 [0xe0, 0x9f, 0xbf] "\uFFFD"        // Overlong encoding of character 0x7ff.
  check-illegal-utf-8 [0xe0, 0x9f, 0xb9] "\uFFFD"        // Overlong encoding of N'Ko exclamation mark.
  check-illegal-utf-8 [0xf0, 0x82, 0x98, 0x83] "\uFFFD"  // Overlong encoding of Unicode snowman.
  check-to-string [0xed, 0x9f, 0xbf] "퟿"                 // 0xd7ff: Last (Hangul) character before the surrogate block.
  check-illegal-utf-8 [0xed, 0xa0, 0x80] "\uFFFD"        // 0xd800: First surrogate.
  check-to-string [0xee, 0x80, 0x80] ""                 // 0xe000: First private use character.
  // The next one is the Apple logo on macOS, and it's the Klingon mummification
  // glyph on Linux, which tells you all you need to know about those two operating systems.
  check-to-string [0xef, 0xA3, 0xBF] ""                 // 0xf8ff: Last private use character.
  check-illegal-utf-8 [0xed, 0xbf, 0xbf] "\uFFFD"        // 0xdfff: Last surrogate.
  check-to-string [0xf4, 0x8f, 0xbf, 0xbf] "􏿿"           // 0x10ffff: Last Unicode character.
  check-illegal-utf-8 [0xf4, 0x90, 0x80, 0x80] "\uFFFD"  // 0x110000: First out-of-range value.
  check-illegal-utf-8 [0xf5, 0x80, 0x80, 0x80] "\uFFFD"  // All UTF-8 sequences starting with f5, f6 or f7 ...
  check-illegal-utf-8 [0xf6, 0x80, 0x80, 0x80] "\uFFFD"  // ... are out of the 0x10ffff range.
  check-illegal-utf-8 [0xf7, 0x80, 0x80, 0x80] "\uFFFD"

  check-illegal-utf-8 ['x', 0x80, 'y'] "x\uFFFDy"
  check-illegal-utf-8 ['x', 0xFF, 'y'] "x\uFFFDy"
  check-illegal-utf-8 ['x', 0xC0, 0x00, 'y'] "x\uFFFD\0y"
  check-illegal-utf-8 ['x', 0xC0, 0x80, 'y'] "x\uFFFDy"
  check-illegal-utf-8 ['x', 0xC0, 0x80, 'y', 0x80] "x\uFFFDy\uFFFD"
  check-illegal-utf-8 ['x', 0xC0, 0x80, 'y', 0xC0] "x\uFFFDy\uFFFD"

  str := "foobar"
  byte-array := ByteArray 10000
  10000.repeat: byte-array[it] = '*'
  write-utf-8-to-byte-array byte-array 2 str[0]
  big-string := byte-array.to-string
  expect-equals big-string big-string
  10000.repeat: expect-equals byte-array[it] (big-string.at --raw it)
  expect-equals 10000 big-string.size

test-string-at:
  big-repetitions := 100
  // The UTF-8 encoding means that byte positions after two-byte characters
  // like æ, ø, å are not valid, and return null when accessed with [].
  str1 := "Søen så sær ud!"
  long-str1 := str1 * big-repetitions
  long-str1.to-byte-array
  expect-equals str1 str1.to-byte-array.to-string
  expect-equals long-str1 long-str1.to-byte-array.to-string
  expect-out-of-bounds: str1[str1.size]
  expect-out-of-bounds: long-str1[long-str1.size]
  test-soen := (: |s offset|
    i := offset
    expect-equals s[i++] 'S'
    expect-equals s[i++] 'ø'
    expect-equals s[i++] null
    expect-equals s[i++] 'e'
    expect-equals s[i++] 'n'
    expect-equals s[i++] ' '
    expect-equals s[i++] 's'
    expect-equals s[i++] 'å'
    expect-equals s[i++] null
    expect-equals s[i++] ' '
    expect-equals s[i++] 's'
    expect-equals s[i++] 'æ'
    expect-equals s[i++] null
    expect-equals s[i++] 'r'
    expect-equals s[i++] ' '
    expect-equals s[i++] 'u'
    expect-equals s[i++] 'd'
    expect-equals s[i++] '!'
    )
  test-soen.call str1 0
  for i := 0; i < big-repetitions; i++:
    test-soen.call long-str1 (i * str1.size)

  // Euro sign is a three byte UTF-8 sequence.
  s := "Only €2"  // Only two Euros.
  i := 0
  expect-equals s[i++] 'O'
  expect-equals s[i++] 'n'
  expect-equals s[i++] 'l'
  expect-equals s[i++] 'y'
  expect-equals s[i++] ' '
  expect-equals s[i++] '€'
  expect-equals s[i++] null
  expect-equals s[i++] null
  expect-equals s[i++] '2'
  expect-out-of-bounds: s[i]
  expect-equals s s.to-byte-array.to-string

  // Some emoji like flags consist of more than one Unicode code point, where
  // each code point is a 4-byte UTF-8 sequence.
  s = "🇪🇺"  // EU flag.
  i = 0
  expect-equals s[i++] '🇪'
  expect-equals s[i++] null
  expect-equals s[i++] null
  expect-equals s[i++] null
  expect-equals s[i++] '🇺'
  expect-equals s[i++] null
  expect-equals s[i++] null
  expect-equals s[i++] null
  expect-out-of-bounds: s[i]
  expect-equals s s.to-byte-array.to-string

  denmark := "🇩🇰"
  sweden := "🇸🇪"
  germany := (denmark.copy 0 4) + (sweden.copy 4 8)
  expect-equals germany "🇩🇪"
  i = 0
  expect-equals germany[i++] '🇩'
  expect-equals germany[i++] null
  expect-equals germany[i++] null
  expect-equals germany[i++] null
  expect-equals germany[i++] '🇪'
  expect-equals germany[i++] null
  expect-equals germany[i++] null
  expect-equals germany[i++] null
  expect-out-of-bounds: germany[i]
  expect-equals germany germany.to-byte-array.to-string

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
        expect-equals (germany.copy x y).size (y - x)
      else:
        expect-illegal-utf-8: germany.copy x y

  for x := 0; x < germany.size; x++:
    for y := x; y <= germany.size; y++:
      copied := germany.copy --force-valid x y
      if x == y: expect-equals 0 copied.size
      adjust := ::
        // From the start to the end of the D.
        if      0 <= it < 4: 0
        // From the D to the E
        else if 4 <= it < 8: 4
        else:                8  // The end of the string.

      adjusted-x := adjust.call x
      adjusted-y := adjust.call y

      if adjusted-x == adjusted-y:                 expect-equals "" copied
      else if adjusted-x == 0 and adjusted-y == 4: expect-equals "🇩" copied
      else if adjusted-x == 0 and adjusted-y == 8: expect-equals "🇩🇪" copied
      else if adjusted-x == 4 and adjusted-y == 8: expect-equals "🇪" copied
      else: throw "bad string"

  // Combining accent, followed by letter.  These stay as two Unicode code
  // points and are not normalized to one code point by string concatenation.
  ahe := "Ah´" + "e"
  i = 0
  expect-equals ahe[i++] 'A'
  expect-equals ahe[i++] 'h'
  expect-equals ahe[i++] '´'
  expect-equals ahe[i++] null
  expect-equals ahe[i++] 'e'
  expect-out-of-bounds: ahe[i]
  expect-equals ahe ahe.to-byte-array.to-string

test-slice-string-at:
  REPETITIONS ::= 3
  short := "Søen så sær ud!"
  str1 := short * REPETITIONS
  slice := "-$str1"[1..]
  expect slice is StringSlice_

  expect-equals str1 slice.to-byte-array.to-string
  expect-out-of-bounds: slice[str1.size]
  test-soen := (: |s offset|
    i := offset
    expect-equals s[i++] 'S'
    expect-equals s[i++] 'ø'
    expect-equals s[i++] null
    expect-equals s[i++] 'e'
    expect-equals s[i++] 'n'
    expect-equals s[i++] ' '
    expect-equals s[i++] 's'
    expect-equals s[i++] 'å'
    expect-equals s[i++] null
    expect-equals s[i++] ' '
    expect-equals s[i++] 's'
    expect-equals s[i++] 'æ'
    expect-equals s[i++] null
    expect-equals s[i++] 'r'
    expect-equals s[i++] ' '
    expect-equals s[i++] 'u'
    expect-equals s[i++] 'd'
    expect-equals s[i++] '!'
    )
  for i := 0; i < REPETITIONS; i++:
    test-soen.call slice (i * short.size)

test-write-to-byte-array:
  expect-equals 1 (utf-8-bytes 0)
  expect-equals 1 (utf-8-bytes 0x7f)
  expect-equals 2 (utf-8-bytes 0x80)
  expect-equals 2 (utf-8-bytes 0x7ff)
  expect-equals 3 (utf-8-bytes 0x800)
  expect-equals 3 (utf-8-bytes 0xffff)
  expect-equals 4 (utf-8-bytes 0x10000)
  expect-equals 4 (utf-8-bytes 0x10ffff)

  check-copy := : | bytes offset |
    bytes.size.repeat:
      if it == offset + 0: expect-equals 'S' bytes[it]
      else if it == offset + 1: expect-equals 0b1100_0011 bytes[it]
      else if it == offset + 2: expect-equals 0b1011_1000 bytes[it]
      else if it == offset + 3: expect-equals 'e' bytes[it]
      else if it == offset + 4: expect-equals 'n' bytes[it]
      else: expect-equals 0 bytes[it]

  str := "Søen"
  bytes := ByteArray str.size
  str.write-to-byte-array bytes
  check-copy.call bytes 0

  bytes = ByteArray 2 * str.size
  str.write-to-byte-array bytes 5
  check-copy.call bytes 5

  bytes = ByteArray 2 * str.size
  str.write-to-byte-array bytes 1 4 5  // NO-WARN
  // Add the missing 'S' and 'n' so we can use our copy-check function.
  expect-equals 0 bytes[4]
  bytes[4] = 'S'
  expect-equals 0 bytes[8]
  bytes[8] = 'n'
  check-copy.call bytes 4

test-slice-write-to-byte-array:
  str := "In ancient times cats were worshipped as gods; they have not forgotten this."

  check-copy := : | bytes offset |
    bytes.size.repeat:
      if offset <= it < offset + str.size:
        expect-equals str[it - offset] bytes[it]
      else:
        expect-equals 0 bytes[it]

  slice := "-$str"[1..]
  expect slice is StringSlice_
  bytes := ByteArray slice.size
  str.write-to-byte-array bytes
  check-copy.call bytes 0

  bytes = ByteArray 2 * str.size
  str.write-to-byte-array bytes 5
  check-copy.call bytes 5

  bytes = ByteArray 10
  str.write-to-byte-array bytes 17 21 5  // NO-WARN
  expect-equals 'c' bytes[5]
  expect-equals 'a' bytes[6]
  expect-equals 't' bytes[7]
  expect-equals 's' bytes[8]
  bytes[5..9].fill 0
  bytes.do: expect-equals 0 it

test-trim:
  expect-equals "foo" "foo"
  expect-equals "foo" " foo".trim
  expect-equals "foo" " foo ".trim
  expect-equals "foo" "    foo    ".trim
  expect-equals "foo" ("  " * 1000 + "foo" + "  " * 1000).trim
  expect-equals "" "".trim
  expect-equals "" " ".trim
  expect-equals "" "  ".trim

  expect-equals "foo" ("foo".trim --left)
  expect-equals "foo" ("foo".trim --right)
  expect-equals "foo" (" foo".trim --left)
  expect-equals "foo" ("foo ".trim --right)
  expect-equals "foo " (" foo ".trim --left)
  expect-equals " foo" (" foo ".trim --right)
  expect-equals "foo    " ("    foo    ".trim --left)
  expect-equals "    foo" ("    foo    ".trim --right)
  expect-equals "" ("".trim --left)
  expect-equals "" (" ".trim --left)
  expect-equals "" ("  ".trim --left)
  expect-equals "" ("".trim --right)
  expect-equals "" (" ".trim --right)
  expect-equals "" ("  ".trim --right)

  expect-equals "www.example.com" ("http://www.example.com".trim --left "http://")
  str := "foobar"
  expect-equals "bar" (str.trim --left "foo")
  expect-equals "foobar" (str.trim --left "")
  expect-equals "foobar" (str.trim --left "bar")
  expect-equals "foobar" (str.trim --left "gee")
  expect-equals "NO_PREFIX" (str.trim --left "bar" --if-absent=: "NO_PREFIX")
  expect-equals "NO_PREFIX" (str.trim --left "gee" --if-absent=: "NO_PREFIX")

  str = "barfoo"
  expect-equals "foo" ("foo.toit".trim --right ".toit")
  expect-equals "bar" (str.trim --right "foo")
  expect-equals "barfoo" (str.trim --right "")
  expect-equals "barfoo" (str.trim --right "bar")
  expect-equals "barfoo" (str.trim --right "gee")
  expect-equals "NO_PREFIX" (str.trim --right "bar" --if-absent=: "NO_PREFIX")
  expect-equals "NO_PREFIX" (str.trim --right "gee" --if-absent=: "NO_PREFIX")

  unicode-whitespace-runes := [
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

  unicode-whitespaces := unicode-whitespace-runes.map: string.from-rune it
  unicode-whitespaces.do:
    expected := "🙈foo🙈"
    prefixed := it + expected
    suffixed := expected + it
    surrounded := it + expected + it
    expect-equals expected prefixed.trim
    expect-equals expected suffixed.trim
    expect-equals expected surrounded.trim
    expect-equals expected (prefixed.trim --left)
    expect-equals expected (suffixed.trim --right)

test-compare-to:
  expect-equals -1 ("a".compare-to "b")
  expect-equals 0 ("a".compare-to "a")
  expect-equals 1 ("b".compare-to "a")
  expect-equals -1 ("ab".compare-to "abc")
  expect-equals 1 ("abc".compare-to "ab")
  expect-equals 1 ("Amélie".compare-to "Amelie")
  expect-equals 1 ("Amélie".compare-to "Amzlie")

  expect-equals -1 ("a".compare-to "a" --if-equal=: -1)
  expect-equals 0 ("a".compare-to "a" --if-equal=: 0)
  expect-equals 1 ("a".compare-to "a" --if-equal=: 1)
  expect-equals
      1
      "a".compare-to "a" --if-equal=:
        "b".compare-to "b" --if-equal=:
          "c".compare-to "c" --if-equal=:
            "z".compare-to "a"
  big-a := "foo" * 1000 + "a"
  big-b := "foo" * 1000 + "b"
  big-c := "foo" * 1000 + "c"
  big-z := "foo" * 1000 + "z"
  expect-equals
      1
      big-a.compare-to big-a --if-equal=:
        big-b.compare-to big-b --if-equal=:
          big-c.compare-to big-c --if-equal=:
            big-z.compare-to big-a

test-slice-compare-to:
  str := "Five exclamation marks, the sure sign of an insane mind."
  slice-a := "-a $str"[1..]
  slice-b := "-b $str"[1..]

  expect-equals -1 (slice-a.compare-to slice-b)
  expect-equals -1 (slice-a.copy.compare-to slice-b)
  expect-equals -1 (slice-a.compare-to slice-b.copy)
  expect-equals 1 (slice-b.compare-to slice-a)
  expect-equals 1 (slice-b.copy.compare-to slice-a)
  expect-equals 1 (slice-b.compare-to slice-a.copy)
  expect-equals 0 (slice-a.compare-to slice-a)
  expect-equals 0 (slice-a.copy.compare-to slice-a)
  expect-equals 0 (slice-a.compare-to slice-a.copy)

test-pad:
  str := "foo"
  expect-equals "  foo" (str.pad --left 5)
  expect-equals "00foo" (str.pad --left 5 '0')

  expect-equals "foo" (str.pad --left 3)
  expect-equals "foo" (str.pad --left 1)
  expect-equals "foo" (str.pad --left -1)

  expect-equals "  foo" (str.pad 5)
  expect-equals "00foo" (str.pad 5 '0')

  expect-equals "foo" (str.pad 3)
  expect-equals "foo" (str.pad 1)
  expect-equals "foo" (str.pad -1)

  expect-equals "foo  " (str.pad --right 5)
  expect-equals "foo00" (str.pad --right 5 '0')

  expect-equals "foo" (str.pad --right 3)
  expect-equals "foo" (str.pad --right 1)
  expect-equals "foo" (str.pad --right -1)

  expect-equals " foo " (str.pad --center 5)
  expect-equals "0foo0" (str.pad --center 5 '0')

  expect-equals " foo  " (str.pad --center 6)
  expect-equals "0foo00" (str.pad --center 6 '0')

  expect-equals "foo" (str.pad --center 3)
  expect-equals "foo" (str.pad --center 1)
  expect-equals "foo" (str.pad --center -1)

  left-pad-big := str.pad 2000
  expect-equals 2000 left-pad-big.size
  expect-equals ' ' left-pad-big[0]
  expect-equals 'o' left-pad-big[1999]

  center-pad-big := str.pad --center 2000
  expect-equals 2000 center-pad-big.size
  expect-equals ' ' center-pad-big[0]
  expect-equals ' ' center-pad-big[199]
  expect-equals "foo" center-pad-big.trim

  right-pad-big := str.pad --right 2000
  expect-equals 2000 right-pad-big.size
  expect-equals 'f' right-pad-big[0]
  expect-equals ' ' right-pad-big[1999]

test-multiply:
  expect-equals "" ("" * 0)
  expect-equals "" ("" * 1)
  expect-equals "" ("" * 3)
  expect-equals "" ("a" * 0)
  expect-equals "a" ("a" * 1)
  expect-equals "aaa" ("a" * 3)
  expect-equals "" ("foo" * 0)
  expect-equals "foo" ("foo" * 1)
  expect-equals "foofoofoo" ("foo" * 3)
  expect-equals "     " (" " * 5)

  big := "abc" * 1000
  expect-equals 3000 big.size
  j := 0
  1000.repeat:
    expect-equals 'a' big[j++]
    expect-equals 'b' big[j++]
    expect-equals 'c' big[j++]

test-slice-multiply:
  str := "Coming back to where you started is not the same as never leaving."
  slice := "-$str"[1..]
  expect slice is StringSlice_

  double := slice * 2
  expect double is String_
  expect-equals (str * 2) double

test-index-of:
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of "so" -1 --if-absent=: throw "NOT_FOUND"
  expect-equals 3 ("Bonsoir".index-of "so" 0 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 ("Bonsoir".index-of "so" 1 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 ("Bonsoir".index-of "so" 2 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 ("Bonsoir".index-of "so" 3 --if-absent=: throw "NOT_FOUND")
  expect-equals 42 ("Bonsoir".index-of "so" 4 --if-absent=: 42)
  expect-equals 42 ("Bonsoir".index-of "so" 5 --if-absent=: 42)
  expect-equals 42 ("Bonsoir".index-of "so" 6 --if-absent=: 42)
  expect-equals 42 ("Bonsoir".index-of "so" 7 --if-absent=: 42)
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of "so" 8 --if-absent=: 42

  expect-equals 3 ("Bonsoir".index-of "soir" 0 --if-absent=: throw "NOT_FOUND")

  expect-error "BAD ARGUMENTS": "Bonsoir".index-of "" -1 --if-absent=: throw "NOT_FOUND"
  expect-equals 0 ("Bonsoir".index-of "" 0 --if-absent=: throw "NOT_FOUND")
  expect-equals 1 ("Bonsoir".index-of "" 1 --if-absent=: throw "NOT_FOUND")
  expect-equals 7 ("Bonsoir".index-of "" 7 --if-absent=: throw "NOT_FOUND")
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of "" 8 --if-absent=: 42
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of "" 6 5 --if-absent=: 42
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of "" 9 9 --if-absent=: 42
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of "" 8 8 --if-absent=: 42
  expect-equals 7 ("Bonsoir".index-of "" 7 7 --if-absent=: 42)
  expect-equals 6 ("Bonsoir".index-of "" 6 6 --if-absent=: 42)
  expect-equals 0 ("".index-of "" --if-absent=: throw "NOT FOUND")

  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" 0 8 --if-absent=: throw "NOT_FOUND"
  expect-equals 3 ("Bonsoir".index-of --last "so" 0 7 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 ("Bonsoir".index-of --last "so" 0 6 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 ("Bonsoir".index-of --last "so" 0 5 --if-absent=: throw "NOT_FOUND")
  expect-equals 42 ("Bonsoir".index-of --last "so" 0 4 --if-absent=: 42)
  expect-equals 42 ("Bonsoir".index-of --last "so" 0 3 --if-absent=: 42)
  expect-equals 42 ("Bonsoir".index-of --last "so" 0 2 --if-absent=: 42)
  expect-equals 42 ("Bonsoir".index-of --last "so" 0 1 --if-absent=: 42)
  expect-equals 42 ("Bonsoir".index-of --last "so" 0 0 --if-absent=: 42)

  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" -1 8 --if-absent=: throw "NOT_FOUND"
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" -1 7 --if-absent=: throw "NOT_FOUND"
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" -1 6 --if-absent=: throw "NOT_FOUND"
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" -1 5 --if-absent=: throw "NOT_FOUND"
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" -1 4 --if-absent=: 42
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" -1 3 --if-absent=: 42
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" -1 2 --if-absent=: 42
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" -1 1 --if-absent=: 42
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "so" -1 0 --if-absent=: 42

  expect-equals 3 ("Bonsoir".index-of --last "soir" 0 7 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 ("Bonsoir".index-of --last "soir" 1 7 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 ("Bonsoir".index-of --last "soir" 2 7 --if-absent=: throw "NOT_FOUND")

  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "" 0 8 --if-absent=: throw "NOT_FOUND"
  expect-equals 7 ("Bonsoir".index-of --last "" 0 7 --if-absent=: throw "NOT_FOUND")
  expect-equals 1 ("Bonsoir".index-of --last "" 0 1 --if-absent=: throw "NOT_FOUND")
  expect-equals 0 ("Bonsoir".index-of --last "" 0 0 --if-absent=: throw "NOT_FOUND")
  expect-error "BAD ARGUMENTS": "Bonsoir".index-of --last "" 0 -1 --if-absent=: 42
  expect-error "BAD ARGUMENTS": ("Bonsoir".index-of --last "" -1 8 --if-absent=: throw "NOT_FOUND")
  expect-error "BAD ARGUMENTS": ("Bonsoir".index-of --last "" -1 7 --if-absent=: throw "NOT_FOUND")
  expect-error "BAD ARGUMENTS": ("Bonsoir".index-of --last "" -1 1 --if-absent=: throw "NOT_FOUND")
  expect-error "BAD ARGUMENTS": ("Bonsoir".index-of --last "" -1 0 --if-absent=: throw "NOT_FOUND")
  expect-error "BAD ARGUMENTS": ("Bonsoir".index-of --last "" -1 -1 --if-absent=: 42)

  expect-equals 0 ("foobar".index-of "foo")
  expect-equals 3 ("foobar".index-of "bar")
  expect-equals -1 ("foo".index-of "bar")

  expect-equals 0 ("foobarfoo".index-of "foo")
  expect-equals 6 ("foobarfoo".index-of "foo" 1)
  expect-equals -1 ("foobarfoo".index-of "foo" 1 8)

  expect-error "BAD ARGUMENTS": "foobarfoo".index-of "foo" -1 999
  expect-error "BAD ARGUMENTS": "foobarfoo".index-of "foo" 1 999

  expect-equals 0 ("".index-of "" 0 0)
  expect-error "BAD ARGUMENTS": "".index-of "" -3 -3
  expect-error "BAD ARGUMENTS": "".index-of "" 2 2

  expect-equals 6 ("foobarfoo".index-of --last "foo")
  expect-equals 6 ("foobarfoo".index-of --last "foo" 1)
  expect-equals -1 ("foobarfoo".index-of --last "foo" 1 6)
  expect-equals 0 ("foobarfoo".index-of --last "foo" 0 8)
  expect-equals 0 ("foobarfoo".index-of --last "foo" 0 5)
  expect-equals 0 ("foobarfoo".index-of --last "foo" 0 8)

  expect-equals -1 ("foobarfoo".index-of --last "gee")
  expect-equals -1 ("foobarfoo".index-of --last "foo" 1 5)
  expect-equals 0  ("foobarfoo".index-of --last "foo" 0 8)

  expect-equals 3   ("foo".index-of "bar" --if-absent=: it.size)
  expect-equals 499 ("foobarfoo".index-of "foo" 1 8 --if-absent=: 499)
  expect-error "BAD ARGUMENTS": "".index-of "" 2 2 --if-absent=: -1
  expect-equals 42 ("foobarfoo".index-of "foo" 1 8 --if-absent=: 42)

  big-string := "Bonsoir" * 1000
  expect-error "BAD ARGUMENTS": big-string.index-of "so" -1 --if-absent=: throw "NOT_FOUND"
  expect-equals 3 (big-string.index-of "so" 0 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 (big-string.index-of "so" 1 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 (big-string.index-of "so" 2 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 (big-string.index-of "so" 3 --if-absent=: throw "NOT_FOUND")
  expect-equals 10 (big-string.index-of "so" 4 --if-absent=: throw "NOT_FOUND")
  expect-equals (7 * 999 + 3) (big-string.index-of "so" (7*999) --if-absent=: throw "NOT_FOUND")

test-slice-index-of:
  str := "Bonsoir - In the beginning there was nothing, which exploded."
  slice := "-$str"[1..]
  expect-error "BAD ARGUMENTS": slice.index-of "so" -1 --if-absent=: throw "NOT_FOUND"
  expect-equals 3 (slice.index-of "so" 0 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 (slice.index-of "so" 1 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 (slice.index-of "so" 2 --if-absent=: throw "NOT_FOUND")
  expect-equals 3 (slice.index-of "so" 3 --if-absent=: throw "NOT_FOUND")
  expect-equals 42 (slice.index-of "so" 4 --if-absent=: 42)
  expect-equals 42 (slice.index-of "so" slice.size --if-absent=: 42)
  expect-error "BAD ARGUMENTS": slice.index-of "so" (slice.size + 1) --if-absent=: 42

test-contains:
  expect-error "BAD ARGUMENTS": "Bonsoir".contains "so" -1
  expect ("Bonsoir".contains "so" 0)
  expect ("Bonsoir".contains "so" 1)
  expect ("Bonsoir".contains "so" 2)
  expect ("Bonsoir".contains "so" 3)
  expect (not "Bonsoir".contains "so" 4)
  expect (not "Bonsoir".contains "so" 5)
  expect (not "Bonsoir".contains "so" 6)
  expect (not "Bonsoir".contains "so" 7)
  expect-error "BAD ARGUMENTS": "Bonsoir".contains "so" 8

  expect ("Bonsoir".contains "soir" 0)

  expect-error "BAD ARGUMENTS": "Bonsoir".contains "" -1
  expect ("Bonsoir".contains "" 0)
  expect ("Bonsoir".contains "" 1)
  expect ("Bonsoir".contains "" 7)
  expect-error "BAD ARGUMENTS": "Bonsoir".contains "" 8
  expect-error "BAD ARGUMENTS": "Bonsoir".contains "" 6 5
  expect-error "BAD ARGUMENTS": "Bonsoir".contains "" 9 9
  expect-error "BAD ARGUMENTS": "Bonsoir".contains "" 8 8
  expect ("Bonsoir".contains "" 7 7)
  expect ("Bonsoir".contains "" 6 6)
  expect ("".contains "")

  expect ("foobar".contains "foo")
  expect ("foobar".contains "bar")
  expect (not "foo".contains "bar")

  expect ("foobarfoo".contains "foo")
  expect ("foobarfoo".contains "foo" 1)
  expect (not "foobarfoo".contains "foo" 1 8)

  expect-error "BAD ARGUMENTS": "foobarfoo".contains "foo" -1 999
  expect-error "BAD ARGUMENTS": "foobarfoo".contains "foo" 1 999

  expect ("".contains "" 0 0)
  expect-error "BAD ARGUMENTS": "".contains "" -3 -3
  expect-error "BAD ARGUMENTS": "".contains "" 2 2

  expect (not "foo".contains "bar")
  expect (not "foobarfoo".contains "foo" 1 8 )
  expect-error "BAD ARGUMENTS": "".contains "" 2 2
  expect (not "foobarfoo".contains "foo" 1 8)

  short-string := "Bonsoir Madame"
  big-string := short-string * 500
  expect (big-string.contains "soir")
  expect (big-string.contains "soir" 7)
  expect (big-string.contains "soir" (7 * 499))
  expect (not big-string.contains "soir" (short-string.size * 499 + 4))
  expect (not big-string.contains "soir" 4 12)

// TODO(florian): move this function to the top.
main:
  test-interpolation
  test-matches
  test-glob
  test-starts-with
  test-ends-with
  test-copy
  test-escaped-characters
  test-conversion-from-byte-array
  test-string-at
  test-write-to-byte-array
  test-split
  test-multiline
  test-trim
  test-compare-to
  test-pad
  test-multiply
  test-do
  test-size
  test-is-empty
  test-at
  test-from-rune
  test-index-of
  test-contains
  test-replace

  test-identical

  test-slice
  test-slice-matches
  test-slice-starts-with
  test-slice-copy
  test-slice-string-at
  test-slice-write-to-byte-array
  test-slice-compare-to
  test-slice-multiply
  test-slice-at
  test-slice-index-of
  test-slice-replace

  test-hash-code

  test-substitute
  test-upper-lower

  expect "fisk".size == 4 --message="string size test"
  expect ("A"[0]) == 'A' --message="string at test"
  expect ("fisk" + "fugl").size == 8

  expect-wrong-object-type:
    x := null
    x = "foo"
    x + 3

test-interpolation:
  x := 42
  expect-equals "x42" "x$(x)"
  expect-equals "x42" "x$x"
  expect-equals "x42y" "x$(x)y"

  xx := 87
  expect-equals "87" "$xx"
  expect-equals "87" "$(xx)"
  expect-equals " 87" " $xx"
  expect-equals " 87" " $(xx)"
  expect-equals " 87 " " $xx "
  expect-equals " 87 " " $(xx) "

  expect-equals "3" "$(1 + 2)"

  expect-equals "1234567890abcde" "1$("2" + "3$("4" + "5$("6" + "7$("8" + "9$("0")a")b")c")d")e"

  neg := -42
  expect-equals "42 -42. -42." "$neg.abs $neg. $neg."
  z := [1, -2, [3, -4]]
  expect-equals "1 -2 2 3 4 42 ["
                "$z[0] $z[1] $z[1].abs $z[2][0] $z[2][1].abs $x ["
  expect-equals "4242342442" "$x$neg.abs$z[2][0]$x$z[2][1].abs$x"

  expect-equals "42\""  "$x\""
  expect-equals "\"42\""  "\"$x\""
  expect-equals "\"\\" """"\\"""
  expect-equals " \"" """ """"
  expect-equals " \"\"" """ """""
  expect-equals " \"\"" """ "\""""
  expect-equals "" """"""
  expect-equals "\" \"" """" """"
  expect-equals "\" \"\"" """" """""
  expect-equals "\"" """""""
  expect-equals "\"\"" """"""""
  expect-equals "42\"\\" """$x"\\"""
  expect-equals "42 \"\"" """$x "\""""
  expect-equals "42 \"\"" """$x """""
  expect-equals "42" """$x"""
  expect-equals "\"42" """"$x"""
  expect-equals "\"\"42" """""$x"""
  expect-equals "42 " """$x """
  expect-equals "42\"" """$x""""
  expect-equals "42 \"" """$x """"
  expect-equals "42\"\"" """$x"""""
  expect-equals "42 \"\"" """$x """""
  expect-equals "\"42\"\\" """\"$x"\\"""
  expect-equals "\"42 \"\"" """\"$x "\""""

  // Interpolation with formatting
  xxx := 234.5455544454
  expect-equals "[         234.55         ]" "[$(%^24.2f xxx)]"

  a := A
  b := B
  expect-equals "A" a.stringify
  expect-equals "A:B" b.stringify

  slice := "12345678911234567892"[1..19]
  expect-equals "-234567891123456789-" "-$slice-"

test-identical:
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

  expect-equals false
    identical str str4
  expect-equals false
    identical str2 str3

  expect-equals false
    identical "Knuth" "Knuþ"

  expect-equals false
    identical "knuth" "Knuth"

  with-null-1 := "knu\00th"
  with-null-2 := "knu\00þ"
  expect-equals with-null-1.size with-null-2.size
  expect-equals false
    identical with-null-1 with-null-2

  huge-1 := "0123456789" * 500            // 5k string will be external.
  huge-2 := "01234567890123456789" * 250  // 5k string will be external.
  expect-equals huge-1.size huge-2.size
  expect-equals true
    identical huge-1 huge-2

  huge-3 := "0123456789" * 499 + "x123456789"
  expect-equals huge-1.size huge-3.size
  expect-equals false
    identical huge-1 huge-3

test-slice:
  str := "XToad the Wet SprocketX"
  slice := str[1..]
  expect slice is StringSlice_
  expect-equals (str.size - 1) slice.size

  slice = str[..]
  expect slice is String_  // No slice as the original is returned.

  slice = str[1..4]
  expect slice is String_  // No slice as it's too small.

  slice = str[..str.size - 1]
  expect slice is StringSlice_
  expect-equals (str.size - 1) slice.size

  slice = str[1..str.size - 1]
  expect slice is StringSlice_
  expect-equals slice "Toad the Wet Sprocket"
  expect-equals (str.size - 2) slice.size

  slice2 := slice[..]
  expect (identical slice slice2)

  slice2 = slice[..4]
  expect-equals "Toad" slice2
  expect slice2 is String_  // Too short.

  slice2 = slice[..slice.size - 1]
  expect slice2 is StringSlice_
  expect-equals "Toad the Wet Sprocke" slice2

  soeen := "Søen så sær ud!"
  expect-error "ILLEGAL_UTF_8": soeen[2..]
  expect-error "ILLEGAL_UTF_8": soeen[2..2]
  // We are attempting to make a copy of the short string.
  expect-error "ILLEGAL_UTF_8": soeen[1..2]
  expect-error "ILLEGAL_UTF_8": (soeen + soeen)[1..(soeen.size + 2)]
  expect-error "ILLEGAL_UTF_8": (soeen + soeen)[..(soeen.size + 2)]
  expect-error "OUT_OF_BOUNDS": (soeen + soeen)[-1..]
  expect-error "OUT_OF_BOUNDS": (soeen + soeen)[..soeen.size * 2 + 1]

  slice = "-$soeen"[1..]
  expect-error "ILLEGAL_UTF_8": slice[2..]
  // We are attempting to make a copy of the short string.
  expect-error "ILLEGAL_UTF_8": slice[1..2]
  slice = "-$soeen$soeen"[1..]
  expect-error "ILLEGAL_UTF_8": slice[1..(soeen.size + 2)]
  expect-error "ILLEGAL_UTF_8": slice[..(soeen.size + 2)]
  expect-error "OUT_OF_BOUNDS": slice[-1..]
  expect-error "OUT_OF_BOUNDS": slice[..soeen.size * 2 + 1]
  expect-error "OUT_OF_BOUNDS": slice[..soeen.size * 2 + 1]

test-matches:
  expect (not "Toad the Wet Sprocket".matches "Toad" --at=-1) --message="No match before start"
  expect (not "Toad the Wet Sprocket".matches "Toad" --at=1) --message="No match at 1"
  expect (not "Toad the Wet Sprocket".matches "Sprocket" --at=12) --message="No match at 12"
  expect ("Toad the Wet Sprocket".matches "Sprocket" --at=13) --message="Match at end"
  expect (not "Toad the Wet Sprocket".matches "Sprocket" --at=14) --message="No match past end"

  big-string := "Toad" * 1000
  expect (big-string.matches "Toad" --at=0)
  expect (not big-string.matches "Toad" --at=1)
  expect (big-string.matches "Toad" --at=(4000 - 4))
  expect (not big-string.matches "Toad" --at=(4000 - 3))

test-slice-matches:
  expect "XToad the Wet Sprocket"[1..] is StringSlice_
  expect (not "XToad the Wet Sprocket"[1..].matches "Toad" --at=-1)
  expect ("XToad the Wet Sprocket"[1..].matches "Sprocket" --at=13)

  expect "Toad the Wet Sprocket"[1..] is StringSlice_
  expect ("Toad the Wet Sprocket".matches "Toad the Wet Sprocket"[1..] --at=1)

test-glob:
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

test-starts-with:
  expect ("Toad the Wet Sprocket".starts-with "Toad") --message="Match at 0"
  expect (not "Toad the Wet Sprocket".starts-with "Wet")

  big-string := "Toad" * 1000
  expect (big-string.starts-with "Toad")
  expect (not big-string.starts-with "Wet")

test-slice-starts-with:
  slice := "XToad the Wet Sprocket"[1..]
  expect slice is StringSlice_
  expect (slice.starts-with "Toad")
  expect (slice.starts-with slice)
  expect ("Toad the Wet Sprocket 123".starts-with slice)

test-ends-with:
  expect ("Toad the Wet Sprocket".ends-with "Sprocket") --message="Match at end"
  expect ("Toad the Wet Sprocket".ends-with "procket") --message="Match at end"
  expect (not "Toad".ends-with "Sprocket") --message="No match at end"
  expect (not "Toad".ends-with "toad") --message="No match at end"

  big-string := "Toad the Wet" * 500
  expect (big-string.ends-with "Wet")
  expect (not big-string.ends-with "the")
  expect (not big-string.ends-with "XXX")

test-copy:
  expect-equals ("Ostesnaps".copy 0 9) "Ostesnaps"
  expect-equals ("Ostesnaps".copy 0 3) "Ost"
  expect-equals ("Ostesnaps".copy 4 9) "snaps"
  expect-equals ("Ostesnaps".copy 2 8) "tesnap"
  expect-out-of-bounds: "Ostesnaps".copy -1 3
  expect-out-of-bounds: "Ostesnaps".copy 0 10
  expect-out-of-bounds: "Ostesnaps".copy 1 10

  big-string := "Ostesnaps" * 500
  len := "Ostesnaps".size
  expect-equals (big-string.copy 0 3) "Ost"
  expect-equals (big-string.copy 4 9) "snaps"
  expect-equals (big-string.copy 2 8) "tesnap"
  expect-equals (big-string.copy (len * 300 + 0) (len * 300 + 3)) "Ost"
  expect-equals (big-string.copy (len * 300 + 4) (len * 300 + 9)) "snaps"
  expect-equals (big-string.copy (len * 300 + 2) (len * 300 + 8)) "tesnap"
  expect-equals (big-string.copy (len * 499 + 0) (len * 499 + 3)) "Ost"
  expect-equals (big-string.copy (len * 499 + 4) (len * 499 + 9)) "snaps"
  expect-equals (big-string.copy (len * 499 + 2) (len * 499 + 8)) "tesnap"
  expect-out-of-bounds: big-string.copy -1 3
  expect-out-of-bounds: big-string.copy 0 (len * 500 + 1)
  expect-out-of-bounds: big-string.copy 1 (len * 500 + 10)

test-slice-copy:
  toad := "Toad the Wet Sprocket"
  str := "-$toad-"

  slice := str[1..]
  expect slice is StringSlice_
  copy := slice.copy
  expect copy is String_
  expect-equals "$toad-" copy

  slice2 := slice
  expect (identical slice slice2)

  slice = str[..str.size - 1]
  expect slice is StringSlice_
  copy = slice.copy
  expect copy is String_
  expect-equals "-$toad" copy

  slice = str[1..str.size - 1]
  expect slice is StringSlice_
  copy = slice.copy
  expect copy is String_
  expect-equals toad copy

  short := slice[..4]  // Automatically copied because it's short.
  expect short is String_
  expect-equals "Toad" short
  short = slice.copy 0 4
  expect short is String_
  expect-equals "Toad" short

  longer := slice[1..18]
  expect longer is StringSlice_
  expect-equals "oad the Wet Sproc" longer
  longer = slice.copy 1 18
  expect longer is String_
  expect-equals "oad the Wet Sproc" longer
  expect-equals 17 longer.size

split-case haystack needle expectation:
  i := 0
  haystack.split needle:
    expect-equals expectation[i++] it
  expect-equals expectation.size i

test-split:
  split-case "Toad the Wet Sprocket" "e" ["Toad th", " W", "t Sprock", "t"]
  split-case " the dust " " " ["", "the", "dust", ""]
  split-case "of Baja California" "water" ["of Baja California"]
  split-case "Søen så sær ud!" "" ["S", "ø", "e", "n", " ", "s", "å", " ", "s", "æ", "r", " ", "u", "d", "!"]
  // Split currently splits things that are rendered as one glyph if they are
  // separate code points.
  split-case "Flag🇩🇰" "" ["F", "l", "a", "g", "🇩", "🇰"]

  expect-equals ["Toad th", " W", "t Sprock", "t"] ("Toad the Wet Sprocket".split "e")
  expect-equals ["", "the", "dust", ""]            (" the dust ".split " ")
  expect-equals ["a", "b", "c"]                    ("abc".split  "")
  expect-equals ["",""]                            ("foo".split  "foo")
  expect-equals ["a",""]                           ("afoo".split "foo")
  expect-equals ["", "b"]                          ("foob".split "foo")
  expect-equals []                                 ("".split "")
  expect-equals ["€"]                              ("€".split "")
  expect-equals ["€", "1", ",", "2", "3"]          ("€1,23".split "")

  expect-equals ["Toad th", " W", "t Sprock", "t"] ("Toad the Wet Sprocket".split --drop-empty "e")
  expect-equals ["the", "dust"]                    (" the dust ".split --drop-empty" ")
  expect-equals ["a", "b", "c"]                    ("abc".split --drop-empty "")
  expect-equals []                                 ("foo".split --drop-empty "foo")
  expect-equals ["a"]                              ("afoo".split --drop-empty "foo")
  expect-equals ["b"]                              ("foob".split --drop-empty "foo")
  expect-equals []                                 ("".split --drop-empty "")
  expect-equals ["€"]                              ("€".split --drop-empty "")
  expect-equals ["€", "1", ",", "2", "3"]          ("€1,23".split --drop-empty "")

  gadsby := "If youth, throughout all history, had had a champion to stand up for it;"
  expect-equals [gadsby] (gadsby.split "e")

  expect-equals ["Toad th", " Wet Sprocket"] ("Toad the Wet Sprocket".split --at-first "e")
  expect-equals ["", "the dust "]            (" the dust ".split            --at-first " ")
  expect-equals [gadsby]                     (gadsby.split                  --at-first "e")

  expect-equals ["a", "bc"]   ("abc".split   --at-first "")
  expect-equals ["€", ""]     ("€".split     --at-first "")
  expect-equals ["€", "1,23"] ("€1,23".split --at-first "")
  expect-equals ["", ""]      ("foo".split   --at-first "foo")
  expect-equals ["a", ""]     ("afoo".split  --at-first "foo")
  expect-equals ["", "b"]     ("foob".split  --at-first "foo")
  expect-invalid-argument:    ("".split      --at-first "")

  expect-equals ["a", "bc"]   ("abc".split   --drop-empty --at-first "")
  expect-equals ["€"]         ("€".split     --drop-empty --at-first "")
  expect-equals ["€", "1,23"] ("€1,23".split --drop-empty --at-first "")
  expect-equals []            ("foo".split   --drop-empty --at-first "foo")
  expect-equals ["a"]         ("afoo".split  --drop-empty --at-first "foo")
  expect-equals ["b"]         ("foob".split  --drop-empty --at-first "foo")
  expect-invalid-argument:    ("".split      --drop-empty --at-first "")

  big-string := "Toad" * 1000
  expect-equals [big-string] (big-string.split "e")

  split-t := big-string.split "T"
  expect-equals 1001 split-t.size
  expect-equals "" split-t[0]
  1000.repeat: expect-equals "oad" split-t[it + 1]

test-multiline:
  expect-equals "foo" """foo"""
  expect-equals "foo\"bar" """foo"bar"""
  expect-equals "foo\nbar" """foo
bar"""
  expect-equals "foobar" """\
foo\
bar\
"""
  expect-equals "foo\nbar" """\
foo
bar\
"""

  x := 42
  expect-equals "x42" """x$(x)"""
  expect-equals "x42\n" """
x$(x)
"""
  expect-equals "x42" """x$x"""
  expect-equals "x42\n" """
x$x
"""
  expect-equals "x\n42\n" """x
$x
"""
  expect-equals "x42y\n" """
x$(x)y
"""

  expect-equals "x42\" " """x$x" """

  xx := 87
  expect-equals "87" """$xx"""
  expect-equals "87" """$(xx)"""
  expect-equals " 87" """ $xx"""
  expect-equals " 87" """ $(xx)"""
  expect-equals " 87 " """ $xx """
  expect-equals " 87 " """ $(xx) """

  expect-equals "3" """$(1 + 2)"""

  expect-equals "1234567890abcde" """1$("2" + """3$("4" + "5$("6" + """7$("8" + "9$("0")a")b""")c")d""")e"""
  expect-equals "1\n  2  3\n  4567890ab\n  cde" """1
  $("2" + """\
  3
  $("4" + "5$("6" + """7$("8" + "9$("0")a")b
  """)c")d""")e"""

  expect-equals " " """ """
  expect-equals "" """
  """
  expect-equals "" """
       """
  expect-equals "aaa" """
    aaa"""
  expect-equals "aaa\n" """
    aaa
    """
  expect-equals "  foo\n" """
    foo
  """

  expect-equals "" """
  $("")"""
  expect-equals "" """
       $("")"""
  expect-equals "aaa" """
    $("aaa")"""
  expect-equals "aaa\n" """
    $("aaa")
    """
  expect-equals "  foo\n" """
    $("foo")
  """

  expect-equals "foo\nbar" """  $("foo")
  bar"""

  expect-equals "  " """\s """
  expect-equals "  foo\n  bar\n" """
  \s foo
    bar
  """

  expect-equals "  foo\n  bar" """
  \s foo
    bar"""

  // The line after 'foo' is empty.
  expect-equals "foo\n\nbar\n" """
    foo

    bar
    """

  expect-equals "  foo\n\n  bar\n" """
  foo

  bar
"""

  expect-equals "foo bar gee" """
  foo $("bar") gee"""

  // Newlines inside string interpolations don't count for indentation.
  expect-equals "  x" """  $(
    "x")"""

class A:
  stringify:
    return "A"

class B extends A:
  stringify:
    return "$super:B"

test-do:
  accumulated := []
  "abc".do: accumulated.add it
  expect-equals ['a', 'b', 'c'] accumulated

  accumulated = []
  "Flag🇩🇰".do: accumulated.add it
  expect-equals ['F', 'l', 'a', 'g', '🇩', null, null, null, '🇰', null, null, null] accumulated

  accumulated = []
  "Flag🇩🇰".do --runes: accumulated.add it
  expect-equals ['F', 'l', 'a', 'g', '🇩', '🇰'] accumulated

  short := "Flag🇩🇰"
  big-string := short * 1000
  counter := 0
  big-string.do:
    expect-equals short[counter++ % short.size] it
  expect-equals (short.size * 1000) counter

  short-runes := []
  short.do --runes: short-runes.add it
  counter = 0
  big-string.do --runes:
    expect-equals short-runes[counter++ % short-runes.size] it
  expect-equals (short-runes.size * 1000) counter

test-size:
  expect-equals 0 "".size
  expect-equals 1 "a".size
  expect-equals 4 "🇩".size
  expect-equals 8 "🇩🇰".size

  expect-equals 0 ("".size --runes)
  expect-equals 1 ("a".size --runes)
  expect-equals 1 ("🇩".size --runes)
  expect-equals 2 ("🇩🇰".size --runes)

test-is-empty:
  expect "".is-empty
  expect (not "a".is-empty)
  expect ("foobar".copy 0 0).is-empty

  bytes := ByteArray 10000
  for i := 0; i < bytes.size; i++: bytes[i] = 'a'
  big-string := bytes.to-string
  expect (not big-string.is-empty)
  expect (big-string.copy 0 0).is-empty

test-at:
  flag-dk := "Flag🇩🇰"
  expect-equals 'F' flag-dk[0]
  expect-equals 'F' flag-dk[flag-dk.rune-index 0]
  expect-equals 'F' (flag-dk.at --raw 0)

  expect-equals '🇩' flag-dk[4]
  expect-equals '🇩' flag-dk[flag-dk.rune-index 4]
  expect-equals 0xf0 (flag-dk.at --raw 4)

  expect-equals null flag-dk[5]
  expect-equals '🇩' flag-dk[flag-dk.rune-index 5]
  expect-equals 0x9f (flag-dk.at --raw 5)

  big-string := flag-dk * 1000
  expect-equals 'F' big-string[0]
  expect-equals 'F' big-string[big-string.rune-index 0]
  expect-equals 'F' (big-string.at --raw 0)

  expect-equals '🇩' big-string[4]
  expect-equals '🇩' big-string[big-string.rune-index 4]
  expect-equals 0xf0 (big-string.at --raw 4)

  expect-equals null big-string[5]
  expect-equals '🇩' big-string[big-string.rune-index 5]
  expect-equals 0x9f (big-string.at --raw 5)

  expect-equals 'F' big-string[flag-dk.size * 999 + 0]
  expect-equals 'F' big-string[big-string.rune-index flag-dk.size * 999 + 0]
  expect-equals 'F' (big-string.at --raw flag-dk.size * 999 + 0)

  expect-equals '🇩' big-string[flag-dk.size * 999 + 4]
  expect-equals '🇩' big-string[big-string.rune-index flag-dk.size * 999 + 4]
  expect-equals 0xf0 (big-string.at --raw flag-dk.size * 999 + 4)

  expect-equals null big-string[flag-dk.size * 999 + 5]
  expect-equals '🇩' big-string[big-string.rune-index flag-dk.size * 999 + 5]
  expect-equals 0x9f (big-string.at --raw flag-dk.size * 999 + 5)

test-slice-at:
  str := "Flag🇩🇰 - Real stupidity beats artificial intelligence every time."
  slice := "-$str"[1..]
  expect slice is StringSlice_

  expect-equals 'F' slice[0]
  expect-equals 'F' slice[slice.rune-index 0]
  expect-equals 'F' (slice.at --raw 0)

  expect-equals '🇩' slice[4]
  expect-equals '🇩' slice[slice.rune-index 4]
  expect-equals 0xf0 (slice.at --raw 4)

  expect-equals null slice[5]
  expect-equals '🇩' slice[slice.rune-index 5]
  expect-equals 0x9f (slice.at --raw 5)

test-from-rune:
  rune := 0
  str := string.from-rune rune
  expect-equals "\0" str
  str = string.from-runes [rune]
  expect-equals "\0" str

  rune = 1
  str = string.from-rune rune
  expect-equals "\x01" str

  rune = 'a'
  str = string.from-rune rune
  expect-equals "a" str

  interesting-runes := [
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
  interesting-runes.do:
    str = string.from-rune it
    expect-equals 1 (str.size --runes)
    expect-equals it str[0]

  str = string.from-runes interesting-runes
  expect-equals
    interesting-runes.size
    str.size --runes

  expect-invalid-argument:
    string.from-rune -1

  expect-invalid-argument:
    string.from-runes [-1]

  expect-invalid-argument:
    string.from-rune (0x10FFFF + 1)

  expect-invalid-argument:
    string.from-runes [0x10FFFF + 1]

  for rune = 0xD800; rune <= 0xDFFF; rune++:
    expect-invalid-argument:
      string.from-rune rune

  for rune = 0xD800; rune <= 0xDFFF; rune++:
    expect-invalid-argument:
      string.from-runes [rune]

test-replace:
  expect-equals "" ("".replace "not found" "foo")
  expect-equals "" ("foo".replace "foo" "")
  expect-equals "foobar" ("barbar".replace "bar" "foo")
  expect-equals "barfoo" ("barbar".replace "bar" "foo" 1)
  expect-equals "barfoo" ("barbar".replace "bar" "foo" 3)
  expect-equals "barbar" ("barbar".replace "bar" "foo" 1 5)

  call-counter := 0
  expect-equals
    ""
    "".replace "not found":
      call-counter++
      "foo"
  expect-equals 0 call-counter

  expect-equals
    ""
    "foo".replace "foo":
      expect-equals "foo" it
      call-counter++
      ""
  expect-equals 1 call-counter

  call-counter = 0
  expect-equals
    "foobar"
    "barbar".replace "bar":
      expect-equals "bar" it
      call-counter++
      "foo"
  expect-equals 1 call-counter

  call-counter = 0
  expect-equals
    "barfoo"
    "barbar".replace "bar" 1:
      expect-equals "bar" it
      call-counter++
      "foo"
  expect-equals 1 call-counter

  call-counter = 0
  expect-equals
    "barfoo"
    "barbar".replace "bar" 3:
      expect-equals "bar" it
      call-counter++
      "foo"
  expect-equals 1 call-counter

  call-counter = 0
  expect-equals
    "barbar"
    "barbar".replace "bar" 1 3:
      call-counter++
      "foo"
  expect-equals 0 call-counter

  expect-equals "" ("".replace --all "not found" "foo")
  expect-equals "" ("foofoo".replace --all "foo" "")
  expect-equals "x" ("fooxfoo".replace --all "foo" "")
  expect-equals "foofoofoo" ("barbarbar".replace --all "bar" "foo")
  expect-equals "barfoofoo" ("barbarbar".replace --all "bar" "foo" 1)
  expect-equals "barfoofoo" ("barbarbar".replace --all "bar" "foo" 3)
  expect-equals "barbarbar" ("barbarbar".replace --all "bar" "foo" 1 5)

  call-counter = 0
  expect-equals
      ""
      "".replace --all "not found":
        "foo$(call-counter++)"
  expect-equals 0 call-counter

  expect-equals
    ""
    "foofoo".replace --all "foo":
      expect-equals "foo" it
      call-counter++
      ""
  expect-equals 2 call-counter

  call-counter = 0
  expect-equals
    "x"
    "fooxfoo".replace --all "foo":
      expect-equals "foo" it
      call-counter++
      ""
  expect-equals 2 call-counter

  call-counter = 0
  expect-equals
    "foo0foo1foo2"
    "barbarbar".replace --all "bar":
      expect-equals "bar" it
      "foo$(call-counter++)"
  expect-equals 3 call-counter

  call-counter = 0
  expect-equals
    "barfoo0foo1"
    "barbarbar".replace --all "bar" 1:
      expect-equals "bar" it
      "foo$(call-counter++)"
  expect-equals 2 call-counter

  call-counter = 0
  expect-equals
    "barfoo0foo1"
    "barbarbar".replace --all "bar" 3:
      expect-equals "bar" it
      "foo$(call-counter++)"
  expect-equals 2 call-counter

  call-counter = 0
  expect-equals
    "barbarbar"
    "barbarbar".replace --all "bar" 1 5:
      call-counter++
      "foo"
  expect-equals 0 call-counter

test-slice-replace:
  str := "Time is a drug. Too much of it kills you."
  slice := "-$str"[1..]
  expect slice is StringSlice_

  replaced := slice.replace "not-there" "something_else"
  expect (identical slice replaced)

  replaced = slice.replace "Time " "Terry "
  expect replaced is String_
  expect (replaced.starts-with "Terry ")

  slice = "-$str"[1..]
  expect-equals
    str.replace --all "i" "X"
    slice.replace --all "i" "X"

test-hash-code:
  str := "Coffee is a way of stealing time that should by rights belong to your older self."

  hash1 := "".hash-code
  hash2 := "x"[0..0].hash-code
  expect-equals hash1 hash2  // Trivially true, as an empty hash returns the empty string.

  slice := "-$str"[1..]
  expect-equals str.hash-code slice.hash-code

  expect-not hash1 == slice.hash-code

test-substitute:
  MAP ::= {
    "variable": "fixed",
    "value": "cost",
  }
  result := "Replace {{variable}} with {{value}}".substitute: MAP[it]
  expect-equals "Replace fixed with cost" result

  result = "Replace {{variable}} with {{value}} trailing text".substitute: MAP[it]
  expect-equals "Replace fixed with cost trailing text" result

  result = "".substitute: MAP[it]
  expect-equals "" result

  result = "{{variable}}".substitute: MAP[it]
  expect-equals "fixed" result

  result = "42foobarfizz103".substitute --open="foo" --close="fizz": "BAR"
  expect-equals "42BAR103" result

  result = "{{variable}} is not variable".substitute: MAP[it]
  expect-equals "fixed is not variable" result

  // Check that we remember to stringify.
  "The time is {{time}} now.".substitute: Time.now.local

  // Whitespace trimming.
  result = "{{  variable  }} is not variable".substitute: MAP[it]
  expect-equals "fixed is not variable" result

  // Null means no change.
  result = "{{  variable  }} is not variable".substitute: null
  expect-equals "{{  variable  }} is not variable" result

  // The opening sequence can be in the middle.
  result = " - {{{{}} - ".substitute: it == "{{"
  expect-equals " - true - " result

  // But we don't count opens and closes, so the closing sequence can't be in
  // the middle.
  result = " - {{{{}}}} - ".substitute: it == "{{"
  expect-equals " - true}} - " result

test-upper-lower:
  expect-equals "foo" "foo".to-ascii-lower
  expect-equals "foo" "Foo".to-ascii-lower
  expect-equals "foo" "FOO".to-ascii-lower
  expect-equals "FOO" "foo".to-ascii-upper
  expect-equals "FOO" "Foo".to-ascii-upper
  expect-equals "FOO" "FOO".to-ascii-upper
  expect-equals "" "".to-ascii-upper
  expect-equals "" "".to-ascii-lower

  // Unicode chars are not changed.
  expect-equals "søen" "søen".to-ascii-lower
  expect-equals "SøEN" "søen".to-ascii-upper

  // Borderline cases.
  expect-equals "@az[" "@AZ[".to-ascii-lower
  expect-equals "@AZ[" "@AZ[".to-ascii-upper
  expect-equals "`az{" "`az{".to-ascii-lower
  expect-equals "`AZ{" "`az{".to-ascii-upper

  // Contains only ASCII.
  expect "".contains-only-ascii
  expect "foo".contains-only-ascii
  expect "FOO".contains-only-ascii
  expect "\x7f".contains-only-ascii
  expect "\x00".contains-only-ascii
  expect-equals false ("søen".contains-only-ascii)
  expect-equals false ("\x80".contains-only-ascii)
