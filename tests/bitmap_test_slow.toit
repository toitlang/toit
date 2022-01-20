// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import expect show *


import font show *
import bitmap show *
import binary show LITTLE_ENDIAN BIG_ENDIAN byte_swap_16 byte_swap_32

get_test_font byte_array:
  return Font [byte_array]

// Set this to true to get a better test that runs too long.
SLOW := true

main:
  feature_detect
  simple_test
  blit_test
  bitmap_test
  blur_test

bitmap_primitives_present := true
bytemap_primitives_present := true

feature_detect:
  e := catch:
    ba := ByteArray 25
    bytemap_blur ba 5 2
  if e == "UNIMPLEMENTED":
    bytemap_primitives_present = false
  e = catch:
    ba := ByteArray 16
    bitmap_rectangle 0 0 0 1 1 ba 16
  if e == "UNIMPLEMENTED":
    bitmap_primitives_present = false

simple_test:
  if bitmap_primitives_present:
    ba := ByteArray 25
    bitmap_zap ba 1
    expect_equals 0xff ba[0]
    expect_equals 0xff ba[24]
    bitmap_zap ba 0
    expect_equals 0 ba[0]
    expect_equals 0 ba[24]

    12.repeat:
      BIG_ENDIAN.put_uint16 ba
        it * 2
        314 * it
    byte_swap_16 ba[0..24]
    12.repeat:
      read := LITTLE_ENDIAN.uint16 ba it * 2
      expect_equals 314 * it read
    for i := 0; i < 24; i += 4:
      byte_swap_16 ba[i..i + 4]
    12.repeat:
      read := BIG_ENDIAN.uint16 ba it * 2
      expect_equals 314 * it read

    6.repeat:
      LITTLE_ENDIAN.put_uint32 ba
        it * 4
        3141592 * it
    byte_swap_32 ba
    6.repeat:
      read := BIG_ENDIAN.uint32 ba it * 4
      expect_equals 3141592 * it read
    for i := 0; i < 24; i += 4:
      byte_swap_32 ba[i..i + 4]
    6.repeat:
      read := LITTLE_ENDIAN.uint32 ba it * 4
      expect_equals 3141592 * it read

blit_test:
  if bitmap_primitives_present:
    r := #[154, 12, 34]
    g := #[22, 14, 15]
    b := #[65, 192, 44]
    rgb := interleave r g b
    INTERLEAVED := #[154, 22, 65, 12, 14, 192, 34, 15, 44]
    expect_equals INTERLEAVED rgb

    SUB ::= ByteArray 0x100: 0xff - it
    lut rgb rgb SUB
    rgb.size.repeat:
      expect_equals
        0xff - INTERLEAVED[it]
        rgb[it]

    // Table that reverses the order of bits in a byte.
    REVERSED ::= ByteArray 0x100: | x |
      x = (x & 0b1010_1010) >> 1  // Swap adjacent bits.
        | (x & 0b0101_0101) << 1
      x = (x & 0b1100_1100) >> 2  // Swap adjacent crumbs.
        | (x & 0b0011_0011) << 2
      x = (x & 0b1111_0000) >> 4  // Swap adjacent nibbles.
        | (x & 0b0000_1111) << 4
      x

    input    := #[0b0110_1100, 0b1101_1011, 0b0011_1101]
    expected := #[0b0011_0110, 0b1101_1011, 0b1011_1100]
    lut input input REVERSED
    expected.size.repeat:
      expect_equals expected[it] input[it]

    expect_equals "Gbvg sbe gur jva!"
      rot13 "Toit for the win!"

    ba := #[1, 2, 3, 4]

    // Check mask works.
    blit ba ba 4 --mask=0xfe
    ba.size.repeat:
      expect_equals [0, 2, 2, 4][it] ba[it]

    // Check shift works.
    blit ba ba 4 --shift=-1
    ba.size.repeat:
      expect_equals [0, 4, 4, 8][it] ba[it]

    // Check OR works.
    blit ba ba 4 --shift=1 --operation=OR
    ba.size.repeat:
      expect_equals [0, 6, 6, 12][it] ba[it]

    // Check lookup-table, shift, and mask happen in that order.
    INVERT ::= ByteArray 0x100: 0xff - it
    blit ba ba 4 --lookup_table=INVERT --shift=1 --mask=0xba
    ba.size.repeat:
      expect_equals [0xba, 0xb8, 0xb8, 0xb8][it] ba[it]

    // Check add works.
    src := #[0xfd, 0xfe, 0xfe, 0xff, 0xff, 0xff]
    dst := #[0x01, 0x01, 0x02, 0x00, 0x01, 0x02]
    blit src dst 1 --operation=ADD
    dst.size.repeat:
      expect_equals [0xfe, 0xff, 0xff, 0xff, 0xff, 0xff][it] dst[it]

    // Check 'and' works.
    dst = #[0x01, 0x01, 0x02, 0x00, 0x01, 0x02]
    blit src dst 1 --operation=AND
    dst.size.repeat:
      expect_equals [0x01, 0x00, 0x02, 0x00, 0x01, 0x02][it] dst[it]

    // Check 'xor' works.
    dst = #[0x01, 0x01, 0x02, 0x00, 0x01, 0x02]
    blit src dst 1 --operation=XOR
    dst.size.repeat:
      expect_equals [0xfc, 0xff, 0xfc, 0xff, 0xfe, 0xfd][it] dst[it]

    // Check add16 works.
    src = #[0x07, 0xc2, 0x01, 0x01]
    //       0x103       0x3ff       0xfeff      0xffff.
    dst = #[0x03, 0x01, 0xff, 0x03, 0xff, 0xfe, 0xff, 0xff]
    blit src dst 4 --destination_pixel_stride=2 --operation=ADD_16_LE
    dst.size.repeat:
      //             0x10a       0x4c1       0xff00      0xffff.
      expect_equals [0x0a, 0x01, 0xc1, 0x04, 0x00, 0xff, 0xff, 0xff][it] dst[it]

    // Check negative destination pixel strides.
    WIDTH := 4
    IMAGE ::=
      #[0x45, 0x51, 0xa8, 0xca,
        0x6b, 0x3a, 0x88, 0x5d,
        0x56, 0x5a, 0x55, 0x11]

    reversed ::= ByteArray IMAGE.size

    // Reverse every line by using negative destination pixel stride.
    blit IMAGE reversed WIDTH --destination_pixel_stride=-1

    3.repeat: | line |
      WIDTH.repeat: | x |
        expect_equals IMAGE[line * WIDTH + x]
                   reversed[line * WIDTH + WIDTH - 1 - x]


    zero_and_two_reversed ::= ByteArray IMAGE.size

    // Reverse even lines.
    blit IMAGE zero_and_two_reversed WIDTH --destination_pixel_stride=-1 --source_line_stride=WIDTH*2 --destination_line_stride=WIDTH*2
    // Copy odd lines.
    blit IMAGE[WIDTH..] zero_and_two_reversed[WIDTH..] WIDTH --source_line_stride=WIDTH*2 --destination_line_stride=WIDTH*2
    3.repeat: | line |
      WIDTH.repeat: | x |
        if line & 1 == 0:
          expect_equals     IMAGE[line * WIDTH + x]
            zero_and_two_reversed[line * WIDTH + WIDTH - 1 - x]
        else:
          expect_equals     IMAGE[line * WIDTH + x]
            zero_and_two_reversed[line * WIDTH + x]

    odd_lines_reversed ::= ByteArray IMAGE.size

    // Reverse odd lines.
    blit IMAGE[WIDTH..] zero_and_two_reversed[WIDTH..] WIDTH --destination_pixel_stride=-1 --source_line_stride=WIDTH*2 --destination_line_stride=WIDTH*2
    // Copy even lines.
    blit IMAGE zero_and_two_reversed WIDTH --source_line_stride=WIDTH*2 --destination_line_stride=WIDTH*2
    3.repeat: | line |
      WIDTH.repeat: | x |
        if line & 1 == 1:
          expect_equals     IMAGE[line * WIDTH + x]
            zero_and_two_reversed[line * WIDTH + WIDTH - 1 - x]
        else:
          expect_equals     IMAGE[line * WIDTH + x]
            zero_and_two_reversed[line * WIDTH + x]

ROT13 ::= ByteArray 0x100:
  result := it
  if      'n' <= it <= 'z' or 'N' <= it <= 'Z': result -= 13
  else if 'a' <= it <= 'm' or 'A' <= it <= 'M': result += 13
  result  // Final value in the block is used to initialize the ByteArray.

/// Rot13 encode/decode a string.
rot13 str/string -> string:
  byte_array := str.to_byte_array
  lut byte_array byte_array ROT13
  return byte_array.to_string

interleave r g b:
  out := ByteArray r.size * 3
  blit r out      r.size --destination_pixel_stride=3
  blit g out[1..] r.size --destination_pixel_stride=3
  blit b out[2..] r.size --destination_pixel_stride=3
  return out

bitmap_test:
  if not bitmap_primitives_present:
    return
  raw_font_with_dot := [
    0x97, 0xf0, 0x17, 0x70, // Magic number 0x7017f097.
    96, 0, 0, 0, // Length
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // Dummy Sha256 checksum.
    0x92, 't','e','s','t',0, // Font name "logo".
    0x9d, 0, // No copyright message.
    'f', 0x0, 0x0, 0x0, // Unicode range start 0x000000.
    't', 0x7f, 0x0, 0x0, // Unicode range end 0x00007f.
    0,
    1,          // Pixel width.
    1, 1, 0, 0, // Box 1x1 at 0, 0.
    97,         // Code point 97 ('a').
    2,          // 2 bytes of image data.
    0x00 | 0x20,// NEW and the pixel
    0x00,       // Rest of the pixel.
    1,          // Pixel width.
    1, 1, 1, 0, // Box 1x1 at 1, 0.
    98,         // Code point 98 ('b').
    2,          // 2 bytes of image data.
    0x00 | 0x20,// NEW and the pixel.
    0x00,       // Rest of the pixel.
    1,          // Pixel width.
    1, 1, 0, 1, // Box 1x1 at 0, 1.
    99,         // Code point 99 ('c').
    2,          // 2 bytes of image data.
    0x00 | 0x20,// NEW and the pixel.
    0x00,       // Rest of the pixel.
    9,          // Pixel width.
    9, 9, 0, 0, // 9x9 character
    100,        // Code point 100 ('d').
    4,          // 4 bytes of image data.
    0xfc, 0x80, // PREFIX_3 (0b11), PREFIX_3_3 (0b11), ONES(0b11), NEW (0b00), 0x80,
    0xb1, 0x80, // PREFIX_2 (0b10), PREFIX_2_3 (0b11), SAME_10_25 (0b00), 6 (0b01 0b10)     (16x same)
    0xff];      // Terminator.

  len := raw_font_with_dot.size
  ba := ByteArray len: raw_font_with_dot[it]
  dot_font := get_test_font ba
  run_test dot_font
  dot_font.close

run_test dot_font:
  expect_equals 1 (dot_font.pixel_width "a")
  box := dot_font.text_extent "a"
  expect_equals 1 box[0]  // Width.
  expect_equals 1 box[1]  // Height.
  expect_equals 0 box[2]  // x offset.
  expect_equals 0 box[3]  // y offset.

  // Create a 128x64 1-bit frame buffer.
  fb_size := (128 * 64) >> 3
  fb := ByteArray fb_size
  bitmap_zap fb 0
  assert_all_same fb 0

  // The coordinates of a bitmap specify the corners of the pixels, not the center.
  // A character has an origin pixel, which is normally the bottom left pixel when
  // unrotated.
  // When plotting a character with orientation 0 we specify the bottom left of the
  // origin pixel as the position (assuming the character does not go outside
  // its spacing box).  When rotated 90 degrees anticlockwise the position specifies
  // the bottom right of the origin pixel.

  // Draw a series of one-pixel characters just outside the edge of the frame
  // buffer. There should be no pixels set by this.
  128.repeat: | x |
    // A 1-pixel high character drawn at y position 65 goes from line 65 to line 64
    // (coordinates indicate the lines between the pixels).
    bitmap_draw_text x 65 1 ORIENTATION_0 "a" dot_font fb 128
    bitmap_draw_text x 0 1 ORIENTATION_0 "a" dot_font fb 128
    // Rectangles extend down and to the right from their coordinate, so giving a
    // y coordinate of 64 and a height of 1 means it's outside the 0-64 frame buffer.
    bitmap_rectangle x 64 1 1 1 fb 128
    bitmap_rectangle x -1 1 1 1 fb 128
  64.repeat: | y |
    // A 1-pixel high character rotated 90 degrees left drawn at x position 129
    // goes from row 129 to line 128 (coordinates indicate the lines between
    // the pixels).
    bitmap_draw_text 129 y 1 ORIENTATION_90 "a" dot_font fb 128
    bitmap_draw_text 0 y 1 ORIENTATION_90 "a" dot_font fb 128
    // Rectangles extend down and to the right from their coordinate, so giving an
    // x coordinate of 128 and a width of 1 means it's outside the 0-128 frame buffer.
    bitmap_rectangle 128 y 1 1 1 fb 128
    bitmap_rectangle -1 y 1 1 1 fb 128
  128.repeat: | x |
    bitmap_draw_text x 64 1 ORIENTATION_180 "a" dot_font fb 128
    bitmap_draw_text x -1 1 ORIENTATION_180 "a" dot_font fb 128
  64.repeat: | y |
    bitmap_draw_text 128 y 1 ORIENTATION_270 "a" dot_font fb 128
    bitmap_draw_text -1 y 1 ORIENTATION_270 "a" dot_font fb 128

  assert_all_same fb 0

  BY_OFF ::= [1, 2, 0, -1]
  CY_OFF ::= [2, 1, -1, 0]

  // The 'b' character is also just one dot, but offset 1 to the right. What
  // this means depends on the orientation. c offsets one up.
  128.repeat: | x |
    4.repeat: | orientation |
      yoff_b := BY_OFF[orientation]
      bitmap_draw_text x 64+yoff_b 1 orientation "b" dot_font fb 128
      bitmap_draw_text x -1+yoff_b 1 orientation "b" dot_font fb 128
      yoff_c := CY_OFF[orientation]
      bitmap_draw_text x 64+yoff_c 1 orientation "c" dot_font fb 128
      bitmap_draw_text x -1+yoff_c 1 orientation "c" dot_font fb 128

  assert_all_same fb 0

  BX_OFF ::= [-1, 1, 2, 0]
  CX_OFF ::= [0, 2, 1, -1]

  64.repeat: | y |
    4.repeat: | orientation |
      xoff_b := BX_OFF[orientation]
      bitmap_draw_text 128+xoff_b y 1 orientation "b" dot_font fb 128
      bitmap_draw_text -1+xoff_b y 1 orientation "b" dot_font fb 128
      xoff_c := CX_OFF[orientation]
      bitmap_draw_text 128+xoff_c y 1 orientation "c" dot_font fb 128
      bitmap_draw_text -1+xoff_c y 1 orientation "c" dot_font fb 128

  assert_all_same fb 0

  XS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
         127, 126, 125, 124, 123, 122, 121, 120, 119, 118, 117, 116, 115, 114, 113, 112]

  YS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
         63, 62, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 51, 50, 49, 48]

  AX_OFF ::= [0, 1, 1, 0]
  AY_OFF ::= [1, 1, 0, 0]

  // Place the single pixel characters in all orientations all around the edges
  // of the frame buffer.
  XS.do: | x |
    YS.do: | y |
      bitmap_zap fb 0
      4.repeat: | orientation |
        ax := x + AX_OFF[orientation]
        ay := y + AY_OFF[orientation]
        bitmap_draw_text ax ay 1 orientation "a" dot_font fb 128
        if SLOW:
          expect_only_pixel_at fb x y
          bitmap_zap fb 0
        bitmap_rectangle x y 1 1 1 fb 128
        if SLOW:
          expect_only_pixel_at fb x y
          bitmap_zap fb 0
      4.repeat: | orientation |
        bx := x + BX_OFF[orientation]
        by := y + BY_OFF[orientation]
        bitmap_draw_text bx by 1 orientation "b" dot_font fb 128
        if SLOW:
          expect_only_pixel_at fb x y
          bitmap_zap fb 0
        cx := x + CX_OFF[orientation]
        cy := y + CY_OFF[orientation]
        bitmap_draw_text cx cy 1 orientation "c" dot_font fb 128
        if SLOW:
          expect_only_pixel_at fb x y
          bitmap_zap fb 0
      // All the above tests draw a pixel in the same place.  In fast mode we only
      // check once that a single pixel is set.
      if not SLOW:
        expect_only_pixel_at fb x y
      // Use the 9x9 block character.  This just checks for expects in the C++
      // code, it doesn't check that the result looks right.
      4.repeat: | orientation |
        bitmap_draw_text x y 1 orientation "d" dot_font fb 128

  bitmap_zap fb 0
  bitmap_rectangle -8 -8 1 9 9 fb 128
  expect_only_pixel_at fb 0 0
  bitmap_zap fb 0
  bitmap_rectangle -8 63 1 9 9 fb 128
  expect_only_pixel_at fb 0 63
  bitmap_zap fb 0
  bitmap_rectangle 127 63 1 9 9 fb 128
  expect_only_pixel_at fb 127 63
  bitmap_zap fb 0
  bitmap_rectangle 127 -8 1 9 9 fb 128
  expect_only_pixel_at fb 127 0

  // Use the 9x9 block character at the corners to place one pixel.
  bitmap_zap fb 0
  bitmap_draw_text -8 1 1 ORIENTATION_0 "d" dot_font fb 128
  expect_only_pixel_at fb 0 0
  bitmap_zap fb 0
  bitmap_draw_text -8 72 1 ORIENTATION_0 "d" dot_font fb 128
  expect_only_pixel_at fb 0 63
  bitmap_zap fb 0
  bitmap_draw_text 127 72 1 ORIENTATION_0 "d" dot_font fb 128
  expect_only_pixel_at fb 127 63
  bitmap_zap fb 0
  bitmap_draw_text 127 1 1 ORIENTATION_0 "d" dot_font fb 128
  expect_only_pixel_at fb 127 0

  bitmap_zap fb 0
  bitmap_draw_text 1 1 1 ORIENTATION_90 "d" dot_font fb 128
  expect_only_pixel_at fb 0 0
  bitmap_zap fb 0
  bitmap_draw_text 1 72 1 ORIENTATION_90 "d" dot_font fb 128
  expect_only_pixel_at fb 0 63
  bitmap_zap fb 0
  bitmap_draw_text 136 72 1 ORIENTATION_90 "d" dot_font fb 128
  expect_only_pixel_at fb 127 63
  bitmap_zap fb 0
  bitmap_draw_text 136 1 1 ORIENTATION_90 "d" dot_font fb 128
  expect_only_pixel_at fb 127 0

  bitmap_zap fb 0
  bitmap_draw_text 1 -8 1 ORIENTATION_180 "d" dot_font fb 128
  expect_only_pixel_at fb 0 0
  bitmap_zap fb 0
  bitmap_draw_text 1 63 1 ORIENTATION_180 "d" dot_font fb 128
  expect_only_pixel_at fb 0 63
  bitmap_zap fb 0
  bitmap_draw_text 136 63 1 ORIENTATION_180 "d" dot_font fb 128
  expect_only_pixel_at fb 127 63
  bitmap_zap fb 0
  bitmap_draw_text 136 -8 1 ORIENTATION_180 "d" dot_font fb 128
  expect_only_pixel_at fb 127 0

  bitmap_zap fb 0
  bitmap_draw_text -8 -8 1 ORIENTATION_270 "d" dot_font fb 128
  expect_only_pixel_at fb 0 0
  bitmap_zap fb 0
  bitmap_draw_text -8 63 1 ORIENTATION_270 "d" dot_font fb 128
  expect_only_pixel_at fb 0 63
  bitmap_zap fb 0
  bitmap_draw_text 127 63 1 ORIENTATION_270 "d" dot_font fb 128
  expect_only_pixel_at fb 127 63
  bitmap_zap fb 0
  bitmap_draw_text 127 -8 1 ORIENTATION_270 "d" dot_font fb 128
  expect_only_pixel_at fb 127 0

assert_all_same fb value:
  fb.size.repeat: assert: fb[it] == value

expect_only_pixel_at fb x y:
  non_zero_location := -1
  fb.size.repeat:
    byte := fb[it]
    if byte != 0:
      expect_equals -1 non_zero_location  // More than one non-zero pixel?!
      lowest_bit := byte & ~(byte - 1)
      expect_equals 0 (byte & ~lowest_bit)  // More than one bit in the byte?!
      non_zero_location = it
  expect non_zero_location != -1
  index := x + ((y >> 3) << 7)
  expect_equals (1 << (y & 7)) fb[index]

blur_get ba width x y:
  return ba[y * width + x]

blur_set ba width x y value:
  ba[y * width + x] = value

blur_gold ba width x_radius y_radius=x_radius:
  ba2 := ba.copy
  if x_radius == 0: x_radius = 1
  if y_radius == 0: y_radius = 1
  for y := 0; y < ba.size/width; y++:
    for x := x_radius - 1; x < width - (x_radius - 1); x++:
      sum := 0
      if x_radius < 2:
        sum = blur_get ba width x y
      else if x_radius == 2:
        sum += 1 * (blur_get ba width x - 1 y)
        sum += 2 * (blur_get ba width x + 0 y)
        sum += 1 * (blur_get ba width x + 1 y)
        sum >>= 2
      else if x_radius == 3:
        sum += 1 * (blur_get ba width x - 2 y)
        sum += 4 * (blur_get ba width x - 1 y)
        sum += 6 * (blur_get ba width x + 0 y)
        sum += 4 * (blur_get ba width x + 1 y)
        sum += 1 * (blur_get ba width x + 2 y)
        sum >>= 4
      blur_set ba2 width x y sum
  result := ba2.copy
  for x := 0; x < width; x++:
    for y := y_radius - 1; y < ba.size/width - (y_radius - 1); y++:
      sum := 0
      if y_radius < 2:
        sum = blur_get ba2 width x y
      else if y_radius == 2:
        sum += 1 * (blur_get ba2 width x y - 1)
        sum += 2 * (blur_get ba2 width x y + 0)
        sum += 1 * (blur_get ba2 width x y + 1)
        sum >>= 2
      else if y_radius == 3:
        sum += 1 * (blur_get ba2 width x y - 2)
        sum += 4 * (blur_get ba2 width x y - 1)
        sum += 6 * (blur_get ba2 width x y + 0)
        sum += 4 * (blur_get ba2 width x y + 1)
        sum += 1 * (blur_get ba2 width x y + 2)
        sum >>= 4
      blur_set result width x y sum
  return result

blur_compare ba ba2 width x_radius y_radius=x_radius:
  if x_radius < 1: x_radius = 1
  if y_radius < 1: y_radius = 1
  for x := x_radius - 1; x < width - (x_radius - 1); x++:
    for y := y_radius - 1; y < ba.size/width - (y_radius - 1); y++:
      if ba[x + y * width] != ba2[x + y * width]:
        print "Differ at $x $y $(x + y * width): $ba[x + y * width] vs $ba2[x + y * width]"
      expect_equals ba[x + y * width] ba2[x + y * width]

blur_log ba width:
  print ""
  for y := 0; y < ba.size/width; y++:
    line := ""
    for x := 0; x < width; x++:
      line += "$(%3d ba[x + y * width]) "
    print line

blur_test:
  if not bytemap_primitives_present:
    return
  ba := ByteArray 25
  ba[12] = 255
  gold := blur_gold ba 5 2
  bytemap_blur ba 5 2
  blur_compare ba gold 5 2

  ba = ByteArray 25
  13.repeat: ba[it] = 255
  gold = blur_gold ba 5 2
  bytemap_blur ba 5 2
  blur_compare ba gold 5 2

  ba = ByteArray 9
  ba[4] = 255
  gold = blur_gold ba 3 2
  bytemap_blur ba 3 2
  blur_compare ba gold 3 2

  ba = ByteArray 30
  30.repeat: ba[it] = (it * 17) & 0xff
  gold = blur_gold ba 6 2
  bytemap_blur ba 6 2
  blur_compare ba gold 6 2

  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur_gold ba 6 2
  bytemap_blur ba 6 2
  blur_compare ba gold 6 2

  ba = ByteArray 81
  ba[40] = 255
  gold = blur_gold ba 9 3
  bytemap_blur ba 9 3
  blur_compare ba gold 9 3

  // Zero blur.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur_gold ba 6 0
  bytemap_blur ba 6 0
  blur_compare ba gold 6 0

  // X blur 3.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur_gold ba 6 3 0
  bytemap_blur ba 6 3 0
  blur_compare ba gold 6 3 0

  // X blur 2.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur_gold ba 6 2 0
  bytemap_blur ba 6 2 0
  blur_compare ba gold 6 2 0

  // Y blur 3.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur_gold ba 6 0 3
  bytemap_blur ba 6 0 3
  blur_compare ba gold 6 0 3

  // Y blur 2.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur_gold ba 6 0 2
  bytemap_blur ba 6 0 2
  blur_compare ba gold 6 0 2

  // Asymmetric blur.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur_gold ba 6 2 3
  bytemap_blur ba 6 2 3
  blur_compare ba gold 6 2 3

  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur_gold ba 6 2 0
  bytemap_blur ba 6 2 0
  blur_compare ba gold 6 2 0

  ba = ByteArray 81
  ba[40] = 255
  gold = blur_gold ba 9 0 3
  bytemap_blur ba 9 0 3
  blur_compare ba gold 9 0 3
