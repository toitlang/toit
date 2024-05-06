// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import bitmap show *
import font show *

sans10 := null

main:
  error := catch:
    sans10 = Font.get "sans10"
  // Some builds of the VM don't have font support.
  if error == "UNIMPLEMENTED":
    print "No font support"
    return
  else if error:
    throw error

  test-known-pixel-widths
  test-pixel-width-out-of-bounds
  test-pixel-width-bad-utf-8
  test-known-text-extents
  test-missing-glyph-substitution
  test-hash

test-hash:
  sans := Font.get "sans10"
  sans.hash-code

  s := Set
  s.add sans
  expect-equals 1 s.size

  sans2 := Font.get "sans10"
  sans2.hash-code

  s.add sans2
  expect-equals 2 s.size

test-known-pixel-widths:
  expect-equals 0 (sans10.pixel-width "")
  expect-equals 9 (sans10.pixel-width "X")
  expect-equals 18 (sans10.pixel-width "XX")
  expect-equals 9 (sans10.pixel-width "XX" 0 1)
  expect-equals 9 (sans10.pixel-width "X" 0 1)
  expect-equals 3 (sans10.pixel-width "j")
  expect-equals 0 (sans10.pixel-width "j" 0 0)

test-pixel-width-out-of-bounds:
  expect-throw "OUT_OF_BOUNDS": (sans10.pixel-width "" -1 0)  // From is before the beginning.
  expect-throw "OUT_OF_BOUNDS": (sans10.pixel-width "" -1 1)  // From is before the beginning.
  expect-throw "OUT_OF_BOUNDS": (sans10.pixel-width "" 1 1)   // From is past the end.
  expect-throw "OUT_OF_BOUNDS": (sans10.pixel-width "X" -1 0) // From is before the beginning.
  expect-throw "OUT_OF_BOUNDS": (sans10.pixel-width "X" -1 1) // From is before the beginning.
  expect-throw "OUT_OF_BOUNDS": (sans10.pixel-width "X" 1 2)  // To is past the end.
  expect-throw "OUT_OF_BOUNDS": (sans10.pixel-width "X" 2 3)  // From is past the end.
  expect-throw "OUT_OF_BOUNDS": (sans10.pixel-width "X" 1 0)  // From and to reversed.
  expect-equals 0 (sans10.pixel-width "X" 1 1)

  // Bounds that are in the middle of a UTF-8 sequence.
test-pixel-width-bad-utf-8:
  expect-throw "ILLEGAL_UTF_8": sans10.pixel-width "ø" 1 2
  // Because zero-length slices in the middle of UTF-8 sequences are not allowed:
  expect-throw "ILLEGAL_UTF_8": sans10.pixel-width "ø" 1 1
  expect-throw "ILLEGAL_UTF_8": sans10.pixel-width "ø" 0 1

test-known-text-extents:
  box-empty := sans10.text-extent ""
  4.repeat: expect-equals 0 box-empty[it]

  box-X := sans10.text-extent "X"
  expect-equals 9 box-X[0]
  expect-equals 11 box-X[1]
  expect-equals 0 box-X[2]
  expect-equals 0 box-X[3]

  box-XX := sans10.text-extent "XX"
  expect-equals 18 box-XX[0]
  3.repeat: expect-equals box-X[it+1] box-XX[it+1]

  box-j := sans10.text-extent "j"
  expect-equals 3 box-j[0]
  expect-equals 14 box-j[1]
  expect-equals -1 box-j[2]   // j goes to the left of the origin coordinate.
  expect-equals -3 box-j[3]   // j goes below the origin coordinate

  // Sona and Soha fit in the same box.
  expect-equals (sans10.pixel-width "Sona") (sans10.pixel-width "Soha")
  box-ascii := sans10.text-extent "Sona"
  box-latin1 := sans10.text-extent "Soha"
  4.repeat: expect-equals box-ascii[it] box-latin1[it]

test-missing-glyph-substitution:
  WIDTH ::= 16
  HEIGHT ::= 16

  canvas := ByteArray WIDTH * HEIGHT / 8

  bitmap-draw-text
      0     // x
      15    // y
      1     // color
      0     // orientation
      "😹"  // character not in the font - cat with tears of joy.
      sans10
      canvas
      WIDTH

  str-version := ""
  for y := 0; y < HEIGHT; y++:
    str := ""
    for x := 0; x < WIDTH; x++:
      byte := canvas[x + (y >> 3) * WIDTH]
      str += (byte & (1 << (y & 7)) != 0) ? "█" : " "
    print str
    str-version += "$(str.trim --right)\n"

  // Expect mojibake for the 0x01f639 character.
  expect-equals """




     ██   █   ████
    █  █  █   █
    █  █  █   ███
    █  █  █   █
     ██   █   █

      ██  ██   ██
     █   █  █ █  █
    ███    ██  ███
    █  █ █  █   █
     ██   ██  ██

    """ str-version

  expect-not
    sans10.contains "😹"[0]

  expect-not
    sans10.contains "\n"[0]

  expect
    sans10.contains "X"[0]

  expect-not
    sans10.contains 0
  expect-not
    sans10.contains 0x10_ffff
  expect-throw "OUT_OF_RANGE":
    sans10.contains -1
  expect-throw "OUT_OF_RANGE":
    sans10.contains 0x110000
