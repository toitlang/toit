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
    return
  else if error:
    throw error

  test_known_pixel_widths
  test_pixel_width_out_of_bounds
  test_pixel_width_bad_utf_8
  test_known_text_extents
  test_missing_glyph_substitution

test_known_pixel_widths:
  expect_equals 0 (sans10.pixel_width "")
  expect_equals 9 (sans10.pixel_width "X")
  expect_equals 18 (sans10.pixel_width "XX")
  expect_equals 9 (sans10.pixel_width "XX" 0 1)
  expect_equals 9 (sans10.pixel_width "X" 0 1)
  expect_equals 3 (sans10.pixel_width "j")
  expect_equals 0 (sans10.pixel_width "j" 0 0)

test_pixel_width_out_of_bounds:
  expect_throw "OUT_OF_BOUNDS": (sans10.pixel_width "" -1 0)  // From is before the beginning.
  expect_throw "OUT_OF_BOUNDS": (sans10.pixel_width "" -1 1)  // From is before the beginning.
  expect_throw "OUT_OF_BOUNDS": (sans10.pixel_width "" 1 1)   // From is past the end.
  expect_throw "OUT_OF_BOUNDS": (sans10.pixel_width "X" -1 0) // From is before the beginning.
  expect_throw "OUT_OF_BOUNDS": (sans10.pixel_width "X" -1 1) // From is before the beginning.
  expect_throw "OUT_OF_BOUNDS": (sans10.pixel_width "X" 1 2)  // To is past the end.
  expect_throw "OUT_OF_BOUNDS": (sans10.pixel_width "X" 2 3)  // From is past the end.
  expect_throw "OUT_OF_BOUNDS": (sans10.pixel_width "X" 1 0)  // From and to reversed.
  expect_equals 0 (sans10.pixel_width "X" 1 1)

  // Bounds that are in the middle of a UTF-8 sequence.
test_pixel_width_bad_utf_8:
  expect_throw "ILLEGAL_UTF_8": sans10.pixel_width "ø" 1 2
  // Because zero-length slices in the middle of UTF-8 sequences are not allowed:
  expect_throw "ILLEGAL_UTF_8": sans10.pixel_width "ø" 1 1
  expect_throw "ILLEGAL_UTF_8": sans10.pixel_width "ø" 0 1

test_known_text_extents:
  box_empty := sans10.text_extent ""
  4.repeat: expect_equals 0 box_empty[it]

  box_X := sans10.text_extent "X"
  expect_equals 9 box_X[0]
  expect_equals 11 box_X[1]
  expect_equals 0 box_X[2]
  expect_equals 0 box_X[3]

  box_XX := sans10.text_extent "XX"
  expect_equals 18 box_XX[0]
  3.repeat: expect_equals box_X[it+1] box_XX[it+1]

  box_j := sans10.text_extent "j"
  expect_equals 3 box_j[0]
  expect_equals 14 box_j[1]
  expect_equals -1 box_j[2]   // j goes to the left of the origin coordinate.
  expect_equals -3 box_j[3]   // j goes below the origin coordinate

  // Sona and Soha fit in the same box.
  expect_equals (sans10.pixel_width "Sona") (sans10.pixel_width "Soha")
  box_ascii := sans10.text_extent "Sona"
  box_latin1 := sans10.text_extent "Soha"
  4.repeat: expect_equals box_ascii[it] box_latin1[it]

test_missing_glyph_substitution:
  WIDTH ::= 16
  HEIGHT ::= 16

  canvas := ByteArray WIDTH * HEIGHT / 8

  bitmap_draw_text
      0     // x
      15    // y
      1     // color
      0     // orientation
      "😹"  // character not in the font - cat with tears of joy.
      sans10
      canvas
      WIDTH

  str_version := ""
  for y := 0; y < HEIGHT; y++:
    str := ""
    for x := 0; x < WIDTH; x++:
      byte := canvas[x + (y >> 3) * WIDTH]
      str += (byte & (1 << (y & 7)) != 0) ? "█" : " "
    print str
    str_version += "$(str.trim --right)\n"

  // Expect mojibake for the 0x01f639 character.
  expect_equals """




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

    """ str_version

  expect_not
    sans10.contains "😹"[0]

  expect_not
    sans10.contains "\n"[0]

  expect
    sans10.contains "X"[0]

  expect_not
    sans10.contains 0
  expect_not
    sans10.contains 0x10_ffff
  expect_throw "OUT_OF_RANGE":
    sans10.contains -1
  expect_throw "OUT_OF_RANGE":
    sans10.contains 0x110000
