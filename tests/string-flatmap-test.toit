// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  string-test

string-test:
  // Identity map.
  expect-equals "Hello, Wørld!" ("Hello, Wørld!".flat-map: it)

  // Spacing map.
  expect-equals "H e l l o , W ø r l d !" ("Hello, Wørld!".flat-map: it == ' ' ? null : [it, ' ']).trim

  // Rock dots map.
  expect-equals "Mötörhead" (heavy-metalize "Motorhead")
  expect-equals "Spin̈al Tap" (heavy-metalize "Spinal Tap")
  expect-equals "die a⃛rzte" (heavy-metalize "die ärzte")

  // Phonetic alphabet map.
  expect-equals "Tango Oscar India Tango" (natoize "Toit")
  expect-equals "Bravo Romeo Oscar Oscar Kilo Lima Yankee November Niner Niner" (natoize "Brooklyn 99")

  // Non-ASCII to ASCII map.
  simpler := "Søen så sær ud".flat-map:
    if it == 'ø':
      'o'
    else if it == 'å':
      "aa"
    else if it == 'æ':
      "ae"
    else:
      it
  expect-equals "Soen saa saer ud" simpler

  expect-equals "hello, world!" (lower-case "Hello, World!")

lower-case str/string -> string:
  return str.flat-map: | c | ('A' <= c <= 'Z') ? c - 'A' + 'a' : c

heavy-metalize str/string -> string:
  return str.flat-map: | c |
    ROCK-DOTS-MAP_.get c --if-absent=(: c)

natoize str/string -> string:
  result := str.flat-map: | c |
    if 'a' <= c <= 'z':
      [NATO[c - 'a'], " "]
    else if 'A' <= c <= 'Z':
      [NATO[c - 'A'], " "]
    else if '0' <= c <= '9':
      [NATO-NUMBER[c - '0'], " "]
    else:
      ""
  return result.trim

ROCK-DOTS-MAP_ ::= {
    'o': 'ö',
    'u': 'ü',
    'n': "n\u{0308}",
    'ä': "a\u{20db}",  // Triple dots!
}

NATO ::= ["Alfa", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliett", "Kilo", "Lima", "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango", "Uniform", "Victor", "Whiskey", "X-ray", "Yankee", "Zulu"]

NATO-NUMBER := ["Zero", "One", "Two", "Tree", "Fower", "Fife", "Six", "Seven", "Eight", "Niner"]
