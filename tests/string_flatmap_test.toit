// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  string_test

string_test:
  // Identity map.
  expect_equals "Hello, Wørld!" ("Hello, Wørld!".flat_map: it)

  // Spacing map.
  expect_equals "H e l l o , W ø r l d !" ("Hello, Wørld!".flat_map: it == ' ' ? null : [it, ' ']).trim

  // Rock dots map.
  expect_equals "Mötörhead" (heavy_metalize "Motorhead")
  expect_equals "Spin̈al Tap" (heavy_metalize "Spinal Tap")
  expect_equals "die a⃛rzte" (heavy_metalize "die ärzte")

  // Phonetic alphabet map.
  expect_equals "Tango Oscar India Tango" (natoize "Toit")
  expect_equals "Bravo Romeo Oscar Oscar Kilo Lima Yankee November Niner Niner" (natoize "Brooklyn 99")

  // Non-ASCII to ASCII map.
  simpler := "Søen så sær ud".flat_map:
    if it == 'ø':
      'o'
    else if it == 'å':
      "aa"
    else if it == 'æ':
      "ae"
    else:
      it
  expect_equals "Soen saa saer ud" simpler

  expect_equals "hello, world!" (lower_case "Hello, World!")

lower_case str/string -> string:
  return str.flat_map: | c | ('A' <= c <= 'Z') ? c - 'A' + 'a' : c

heavy_metalize str/string -> string:
  return str.flat_map: | c |
    ROCK_DOTS_MAP_.get c --if_absent=(: c)

natoize str/string -> string:
  result := str.flat_map: | c |
    if 'a' <= c <= 'z':
      [NATO[c - 'a'], " "]
    else if 'A' <= c <= 'Z':
      [NATO[c - 'A'], " "]
    else if '0' <= c <= '9':
      [NATO_NUMBER[c - '0'], " "]
    else:
      ""
  return result.trim

ROCK_DOTS_MAP_ ::= {
    'o': 'ö',
    'u': 'ü',
    'n': "n\u{0308}",
    'ä': "a\u{20db}",  // Triple dots!
}

NATO ::= ["Alfa", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliett", "Kilo", "Lima", "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango", "Uniform", "Victor", "Whiskey", "X-ray", "Yankee", "Zulu"]

NATO_NUMBER := ["Zero", "One", "Two", "Tree", "Fower", "Fife", "Six", "Seven", "Eight", "Niner"]
