// Copyright (C) 2022 Toitware ApS. All rights reserved.

import font show *
import font.x11_100dpi.sans.sans_08 as sans_08
import expect show *

import line_wrap show line_wrap

is_alnum_ char/int?:
  if char == null: throw "UTF-8"
  if char >= 0x80: return true
  if '0' <= char <= '9': return true
  if 'a' <= char <= 'z': return true
  if 'A' <= char <= 'Z': return true
  return false

can_split_ str/string i/int -> bool:
  if not 0 < i < str.size: return true
  before_position := i - 1
  while not str[before_position]: before_position--
  // Split around spaces.
  if str[before_position] == ' ' or str[i] == ' ': return true
  before := is_alnum_ str[before_position]
  return not before

main:
  fixed_width
  variable_width

fixed_width:
  wrapped_hello := line_wrap "Hello, World!" 5
    --compute_width=: | text from to | to - from
    --can_split=: true
  expect_equals wrapped_hello ["Hello", ", Wor", "ld!"]
  
  word_wrapped_hello := line_wrap "Hello, World!" 5
    --compute_width=: | text from to | to - from
    --can_split=: | text index | can_split_ text index
  expect_equals word_wrapped_hello ["Hello", ",", "World", "!"]

  wrapped_fox := line_wrap "Now is the time for all good men to come to the aid of the party." 10
    --compute_width=: | text from to | to - from
    --can_split=: | text index | can_split_ text index
  expect_equals wrapped_fox ["Now is the", "time for", "all good", "men to", "come to", "the aid of", "the party."]
  wrapped_fox.do: expect it.size <= 10

variable_width:
  sans := Font [sans_08.ASCII]

  wrapped_hello := line_wrap "Hello, World!" 25
    --compute_width=: | text from to | sans.pixel_width text from to
    --can_split=: true
  expect_equals wrapped_hello ["Hello", ", Wor", "ld!"]
  wrapped_hello.do:
    expect (sans.pixel_width it) <= 25

  word_wrapped_hello := line_wrap "Hello, World!" 25
    --compute_width=: | text from to | sans.pixel_width text from to
    --can_split=: | text index | can_split_ text index

  word_wrapped_hello.do:
    expect (sans.pixel_width it) <= 25
  expect_equals word_wrapped_hello ["Hello", ",", "Worl", "d!"]

  word_wrapped_fox := line_wrap "Now is the time for all good men to come to the aid of the party." 50
    --compute_width=: | text from to | sans.pixel_width text from to
    --can_split=: | text index | can_split_ text index

  word_wrapped_fox.do:
    expect (sans.pixel_width it) <= 50
  expect_equals word_wrapped_fox ["Now is the", "time for all", "good men", "to come to", "the aid of", "the party."]

  word_wrapped_utf_8 := line_wrap "Søen så sær ud.  Motörhead!  Þétt eins og tígrisdýr." 4
    --compute_width=: | text from to | (text.copy from to).size --runes
    --can_split=: | text index | can_split_ text index

  word_wrapped_utf_8.do:
    expect (it.size --runes) <= 4
  expect_equals word_wrapped_utf_8 ["Søen", "så", "sær", "ud.", "Motö", "rhea", "d!", "Þétt", "eins", "og", "tígr", "isdý", "r."]

  word_wrapped_punctuation := line_wrap "C3P0. Is a 1:1 copy of X/2. X XY! XYZ!" 4
    --compute_width=: | text from to | (text.copy from to).size --runes
    --can_split=: | text index | can_split_ text index

  word_wrapped_punctuation.do:
    expect (it.size --runes) <= 4
  expect_equals word_wrapped_punctuation ["C3P0", ". Is", "a 1:", "1", "copy", "of", "X/2.", "X", "XY!", "XYZ!"]

  one_pixel_wrapped_hello := line_wrap "Hellø, World!" 1
    --compute_width=: | text from to | sans.pixel_width text from to
    --can_split=: | text index | can_split_ text index

  one_pixel_wrapped_hello_split_anywhere := line_wrap "Hellø, World!" 1
    --compute_width=: | text from to | sans.pixel_width text from to
    --can_split=: true

  expect_equals
    one_pixel_wrapped_hello
    ["H", "e", "l", "l", "ø", ",", "W", "o", "r", "l", "d", "!"]

  expect_equals
    one_pixel_wrapped_hello
    one_pixel_wrapped_hello_split_anywhere

  if platform != "FreeRTOS":
    pixel_long := "I wholly disapprove of what you say and will defend to the death your right to say it. "
    long := pixel_long

    // Takes < one second, but more than one minute if the algorithm is quadratic.
    15.repeat: long += long
    line_wrap long 72
      --compute_width=: | _ from to | to - from
      --can_split=: | text index | can_split_ text index

    // Takes < two seconds, but about one minute if the algorithm is quadratic.
    13.repeat: pixel_long += pixel_long
    line_wrap pixel_long 600
      --compute_width=: | text from to | sans.pixel_width text from to
      --can_split=: | text index | can_split_ text index
