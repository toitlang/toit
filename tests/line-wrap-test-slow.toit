// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import font show *
import font-x11-adobe.sans-08
import expect show *
import system
import system show platform

import line-wrap show line-wrap

is-alnum_ char/int?:
  if char == null: throw "UTF-8"
  if char >= 0x80: return true
  if '0' <= char <= '9': return true
  if 'a' <= char <= 'z': return true
  if 'A' <= char <= 'Z': return true
  return false

can-split_ str/string i/int -> bool:
  if not 0 < i < str.size: return true
  before-position := i - 1
  while not str[before-position]: before-position--
  // Split around spaces.
  if str[before-position] == ' ' or str[i] == ' ': return true
  before := is-alnum_ str[before-position]
  return not before

main:
  fixed-width
  variable-width

fixed-width:
  wrapped-hello := line-wrap "Hello, World!" 5
    --compute-width=: | text from to | to - from
    --can-split=: true
  expect-equals wrapped-hello ["Hello", ", Wor", "ld!"]
  
  word-wrapped-hello := line-wrap "Hello, World!" 5
    --compute-width=: | text from to | to - from
    --can-split=: | text index | can-split_ text index
  expect-equals word-wrapped-hello ["Hello", ",", "World", "!"]

  wrapped-fox := line-wrap "Now is the time for all good men to come to the aid of the party." 10
    --compute-width=: | text from to | to - from
    --can-split=: | text index | can-split_ text index
  expect-equals wrapped-fox ["Now is the", "time for", "all good", "men to", "come to", "the aid of", "the party."]
  wrapped-fox.do: expect it.size <= 10

variable-width:
  sans := Font [sans-08.ASCII]

  wrapped-hello := line-wrap "Hello, World!" 25
    --compute-width=: | text from to | sans.pixel-width text from to
    --can-split=: true
  expect-equals wrapped-hello ["Hello", ", Wor", "ld!"]
  wrapped-hello.do:
    expect (sans.pixel-width it) <= 25

  word-wrapped-hello := line-wrap "Hello, World!" 25
    --compute-width=: | text from to | sans.pixel-width text from to
    --can-split=: | text index | can-split_ text index

  word-wrapped-hello.do:
    expect (sans.pixel-width it) <= 25
  expect-equals word-wrapped-hello ["Hello", ",", "Worl", "d!"]

  word-wrapped-fox := line-wrap "Now is the time for all good men to come to the aid of the party." 50
    --compute-width=: | text from to | sans.pixel-width text from to
    --can-split=: | text index | can-split_ text index

  word-wrapped-fox.do:
    expect (sans.pixel-width it) <= 50
  expect-equals word-wrapped-fox ["Now is the", "time for all", "good men", "to come to", "the aid of", "the party."]

  word-wrapped-utf-8 := line-wrap "Søen så sær ud.  Motörhead!  Þétt eins og tígrisdýr." 4
    --compute-width=: | text from to | (text.copy from to).size --runes
    --can-split=: | text index | can-split_ text index

  word-wrapped-utf-8.do:
    expect (it.size --runes) <= 4
  expect-equals word-wrapped-utf-8 ["Søen", "så", "sær", "ud.", "Motö", "rhea", "d!", "Þétt", "eins", "og", "tígr", "isdý", "r."]

  word-wrapped-punctuation := line-wrap "C3P0. Is a 1:1 copy of X/2. X XY! XYZ!" 4
    --compute-width=: | text from to | (text.copy from to).size --runes
    --can-split=: | text index | can-split_ text index

  word-wrapped-punctuation.do:
    expect (it.size --runes) <= 4
  expect-equals word-wrapped-punctuation ["C3P0", ". Is", "a 1:", "1", "copy", "of", "X/2.", "X", "XY!", "XYZ!"]

  one-pixel-wrapped-hello := line-wrap "Hellø, World!" 1
    --compute-width=: | text from to | sans.pixel-width text from to
    --can-split=: | text index | can-split_ text index

  one-pixel-wrapped-hello-split-anywhere := line-wrap "Hellø, World!" 1
    --compute-width=: | text from to | sans.pixel-width text from to
    --can-split=: true

  expect-equals
    one-pixel-wrapped-hello
    ["H", "e", "l", "l", "ø", ",", "W", "o", "r", "l", "d", "!"]

  expect-equals
    one-pixel-wrapped-hello
    one-pixel-wrapped-hello-split-anywhere

  if platform != system.PLATFORM-FREERTOS:
    pixel-long := "I wholly disapprove of what you say and will defend to the death your right to say it. "
    long := pixel-long

    // Takes < one second, but more than one minute if the algorithm is quadratic.
    15.repeat: long += long
    line-wrap long 72
      --compute-width=: | _ from to | to - from
      --can-split=: | text index | can-split_ text index

    // Takes < two seconds, but about one minute if the algorithm is quadratic.
    13.repeat: pixel-long += pixel-long
    line-wrap pixel-long 600
      --compute-width=: | text from to | sans.pixel-width text from to
      --can-split=: | text index | can-split_ text index
