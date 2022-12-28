import expect show *

main:
  string_test
  byte_array_test

byte_array_test:
  // Stays a byte array.
  expect_equals #[1, 2, 3] (#[0, 1, 2].map: it + 1)
  // Negative result makes it a list.
  expect_equals [-1, 0, 1] (#[0, 1, 2].map: it - 1)
  POWERS ::= ByteArray 8: 1 << it
  // Out of range result makes it a list.
  expect_equals [2, 4, 8, 16, 32, 64, 128, 256] (POWERS.map: it * 2)
  // Works on byte array slices.
  expect_equals #[4, 8, 16, 32, 64, 128] (POWERS[1..7].map: it * 2)
  // Non-int values make it a list.
  RANDOM ::= [255, "hest", "fisk", null]
  expect_equals RANDOM (#[0, 1, 2, 3].map: RANDOM[it])

string_test:
  // Identity map.
  expect_equals "Hello, Wørld!" ("Hello, Wørld!".map: it)

  // Spacing map.
  expect_equals "H e l l o , W ø r l d !" ("Hello, Wørld!".map: it == ' ' ? null : [it, ' ']).trim

  // Rock dots map.
  expect_equals "Mötörhead" (heavy_metalize "Motorhead")
  expect_equals "Spin̈al Tap" (heavy_metalize "Spinal Tap")
  expect_equals "die a⃛rzte" (heavy_metalize "die ärzte")

  // Phonetic alphabet map.
  expect_equals "Tango Oscar India Tango" (natoize "Toit")
  expect_equals "Bravo Romeo Oscar Oscar Kilo Lima Yankee November Niner Niner" (natoize "Brooklyn 99")

  // Non-ASCII to ASCII map.
  simpler := "Søen så sær ud".map:
    if it == 'ø':
      'o'
    else if it == 'å':
      "aa"
    else if it == 'æ':
      "ae"
    else:
      it
  expect_equals "Soen saa saer ud" simpler

heavy_metalize str/string -> string:
  return str.map: | c |
    ROCK_DOTS_MAP_.get c --if_absent=(: c)

natoize str/string -> string:
  result := str.map: | c |
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
