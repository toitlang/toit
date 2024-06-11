// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import font show *
import bitmap show *
import io show LITTLE-ENDIAN BIG-ENDIAN ByteOrder

import .io-utils

get-test-font byte-array:
  return Font [byte-array]

// Set this to true to get a better test that runs too long.
SLOW := true

main:
  feature-detect
  bytemap-test
  simple-test
  blit-test
  bitmap-test
  blur-test
  io-data-test
  composit-test

bitmap-primitives-present := true
bytemap-primitives-present := true

feature-detect:
  e := catch:
    ba := ByteArray 25
    bytemap-blur ba 5 2
  if e == "UNIMPLEMENTED":
    bytemap-primitives-present = false
  e = catch:
    ba := ByteArray 16
    bitmap-rectangle 0 0 0 1 1 ba 16
  if e == "UNIMPLEMENTED":
    bitmap-primitives-present = false

simple-test:
  if bitmap-primitives-present:
    ba := ByteArray 25
    bitmap-zap ba 1
    expect-equals 0xff ba[0]
    expect-equals 0xff ba[24]
    bitmap-zap ba 0
    expect-equals 0 ba[0]
    expect-equals 0 ba[24]

    12.repeat:
      BIG-ENDIAN.put-uint16 ba
        it * 2
        314 * it
    ByteOrder.swap-16 ba[0..24]
    12.repeat:
      read := LITTLE-ENDIAN.uint16 ba it * 2
      expect-equals 314 * it read
    for i := 0; i < 24; i += 4:
      ByteOrder.swap-16 ba[i..i + 4]
    12.repeat:
      read := BIG-ENDIAN.uint16 ba it * 2
      expect-equals 314 * it read

    6.repeat:
      LITTLE-ENDIAN.put-uint32 ba
        it * 4
        3141592 * it
    ByteOrder.swap-32 ba
    6.repeat:
      read := BIG-ENDIAN.uint32 ba it * 4
      expect-equals 3141592 * it read
    for i := 0; i < 24; i += 4:
      ByteOrder.swap-32 ba[i..i + 4]
    6.repeat:
      read := LITTLE-ENDIAN.uint32 ba it * 4
      expect-equals 3141592 * it read

blit-test:
  if bitmap-primitives-present:
    r := #[154, 12, 34]
    g := #[22, 14, 15]
    b := #[65, 192, 44]
    rgb := interleave r g b
    INTERLEAVED := #[154, 22, 65, 12, 14, 192, 34, 15, 44]
    expect-equals INTERLEAVED rgb

    SUB ::= ByteArray 0x100: 0xff - it
    lut rgb rgb SUB
    rgb.size.repeat:
      expect-equals
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
      expect-equals expected[it] input[it]

    expect-equals "Gbvg sbe gur jva!"
      rot13 "Toit for the win!"

    ba := #[1, 2, 3, 4]

    // Check mask works.
    blit ba ba 4 --mask=0xfe
    ba.size.repeat:
      expect-equals [0, 2, 2, 4][it] ba[it]

    // Check shift works.
    blit ba ba 4 --shift=-1
    ba.size.repeat:
      expect-equals [0, 4, 4, 8][it] ba[it]

    // Check OR works.
    blit ba ba 4 --shift=1 --operation=OR
    ba.size.repeat:
      expect-equals [0, 6, 6, 12][it] ba[it]

    // Check lookup-table, shift, and mask happen in that order.
    INVERT ::= ByteArray 0x100: 0xff - it
    blit ba ba 4 --lookup-table=INVERT --shift=1 --mask=0xba
    ba.size.repeat:
      expect-equals [0xba, 0xb8, 0xb8, 0xb8][it] ba[it]

    // Check add works.
    src := #[0xfd, 0xfe, 0xfe, 0xff, 0xff, 0xff]
    dst := #[0x01, 0x01, 0x02, 0x00, 0x01, 0x02]
    blit src dst 1 --operation=ADD
    dst.size.repeat:
      expect-equals [0xfe, 0xff, 0xff, 0xff, 0xff, 0xff][it] dst[it]

    // Check 'and' works.
    dst = #[0x01, 0x01, 0x02, 0x00, 0x01, 0x02]
    blit src dst 1 --operation=AND
    dst.size.repeat:
      expect-equals [0x01, 0x00, 0x02, 0x00, 0x01, 0x02][it] dst[it]

    // Check 'xor' works.
    dst = #[0x01, 0x01, 0x02, 0x00, 0x01, 0x02]
    blit src dst 1 --operation=XOR
    dst.size.repeat:
      expect-equals [0xfc, 0xff, 0xfc, 0xff, 0xfe, 0xfd][it] dst[it]

    // Check add16 works.
    src = #[0x07, 0xc2, 0x01, 0x01]
    //       0x103       0x3ff       0xfeff      0xffff.
    dst = #[0x03, 0x01, 0xff, 0x03, 0xff, 0xfe, 0xff, 0xff]
    blit src dst 4 --destination-pixel-stride=2 --operation=ADD-16-LE
    dst.size.repeat:
      //             0x10a       0x4c1       0xff00      0xffff.
      expect-equals [0x0a, 0x01, 0xc1, 0x04, 0x00, 0xff, 0xff, 0xff][it] dst[it]

    // Check negative destination pixel strides.
    WIDTH := 4
    IMAGE ::=
      #[0x45, 0x51, 0xa8, 0xca,
        0x6b, 0x3a, 0x88, 0x5d,
        0x56, 0x5a, 0x55, 0x11]

    reversed ::= ByteArray IMAGE.size

    // Reverse every line by using negative destination pixel stride.
    blit IMAGE reversed WIDTH --destination-pixel-stride=-1

    3.repeat: | line |
      WIDTH.repeat: | x |
        expect-equals IMAGE[line * WIDTH + x]
                   reversed[line * WIDTH + WIDTH - 1 - x]


    zero-and-two-reversed ::= ByteArray IMAGE.size

    // Reverse even lines.
    blit IMAGE zero-and-two-reversed WIDTH --destination-pixel-stride=-1 --source-line-stride=WIDTH*2 --destination-line-stride=WIDTH*2
    // Copy odd lines.
    blit IMAGE[WIDTH..] zero-and-two-reversed[WIDTH..] WIDTH --source-line-stride=WIDTH*2 --destination-line-stride=WIDTH*2
    3.repeat: | line |
      WIDTH.repeat: | x |
        if line & 1 == 0:
          expect-equals     IMAGE[line * WIDTH + x]
            zero-and-two-reversed[line * WIDTH + WIDTH - 1 - x]
        else:
          expect-equals     IMAGE[line * WIDTH + x]
            zero-and-two-reversed[line * WIDTH + x]

    odd-lines-reversed ::= ByteArray IMAGE.size

    // Reverse odd lines.
    blit IMAGE[WIDTH..] zero-and-two-reversed[WIDTH..] WIDTH --destination-pixel-stride=-1 --source-line-stride=WIDTH*2 --destination-line-stride=WIDTH*2
    // Copy even lines.
    blit IMAGE zero-and-two-reversed WIDTH --source-line-stride=WIDTH*2 --destination-line-stride=WIDTH*2
    3.repeat: | line |
      WIDTH.repeat: | x |
        if line & 1 == 1:
          expect-equals     IMAGE[line * WIDTH + x]
            zero-and-two-reversed[line * WIDTH + WIDTH - 1 - x]
        else:
          expect-equals     IMAGE[line * WIDTH + x]
            zero-and-two-reversed[line * WIDTH + x]

ROT13 ::= ByteArray 0x100:
  result := it
  if      'n' <= it <= 'z' or 'N' <= it <= 'Z': result -= 13
  else if 'a' <= it <= 'm' or 'A' <= it <= 'M': result += 13
  result  // Final value in the block is used to initialize the ByteArray.

/// Rot13 encode/decode a string.
rot13 str/string -> string:
  byte-array := str.to-byte-array
  lut byte-array byte-array ROT13
  return byte-array.to-string

interleave r g b:
  out := ByteArray r.size * 3
  blit r out      r.size --destination-pixel-stride=3
  blit g out[1..] r.size --destination-pixel-stride=3
  blit b out[2..] r.size --destination-pixel-stride=3
  return out

bitmap-test:
  if not bitmap-primitives-present:
    return
  raw-font-with-dot := [
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

  len := raw-font-with-dot.size
  ba := ByteArray len: raw-font-with-dot[it]
  dot-font := get-test-font ba
  run-test dot-font
  dot-font.close

run-test dot-font:
  expect-equals 1 (dot-font.pixel-width "a")
  box := dot-font.text-extent "a"
  expect-equals 1 box[0]  // Width.
  expect-equals 1 box[1]  // Height.
  expect-equals 0 box[2]  // x offset.
  expect-equals 0 box[3]  // y offset.

  // Create a 128x64 1-bit frame buffer.
  fb-size := (128 * 64) >> 3
  fb := ByteArray fb-size
  bitmap-zap fb 0
  assert-all-same fb 0

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
    bitmap-draw-text x 65 1 ORIENTATION-0 "a" dot-font fb 128
    bitmap-draw-text x 0 1 ORIENTATION-0 "a" dot-font fb 128
    // Rectangles extend down and to the right from their coordinate, so giving a
    // y coordinate of 64 and a height of 1 means it's outside the 0-64 frame buffer.
    bitmap-rectangle x 64 1 1 1 fb 128
    bitmap-rectangle x -1 1 1 1 fb 128
  64.repeat: | y |
    // A 1-pixel high character rotated 90 degrees left drawn at x position 129
    // goes from row 129 to line 128 (coordinates indicate the lines between
    // the pixels).
    bitmap-draw-text 129 y 1 ORIENTATION-90 "a" dot-font fb 128
    bitmap-draw-text 0 y 1 ORIENTATION-90 "a" dot-font fb 128
    // Rectangles extend down and to the right from their coordinate, so giving an
    // x coordinate of 128 and a width of 1 means it's outside the 0-128 frame buffer.
    bitmap-rectangle 128 y 1 1 1 fb 128
    bitmap-rectangle -1 y 1 1 1 fb 128
  128.repeat: | x |
    bitmap-draw-text x 64 1 ORIENTATION-180 "a" dot-font fb 128
    bitmap-draw-text x -1 1 ORIENTATION-180 "a" dot-font fb 128
  64.repeat: | y |
    bitmap-draw-text 128 y 1 ORIENTATION-270 "a" dot-font fb 128
    bitmap-draw-text -1 y 1 ORIENTATION-270 "a" dot-font fb 128

  assert-all-same fb 0

  BY-OFF ::= [1, 2, 0, -1]
  CY-OFF ::= [2, 1, -1, 0]

  // The 'b' character is also just one dot, but offset 1 to the right. What
  // this means depends on the orientation. c offsets one up.
  128.repeat: | x |
    4.repeat: | orientation |
      yoff-b := BY-OFF[orientation]
      bitmap-draw-text x 64+yoff-b 1 orientation "b" dot-font fb 128
      bitmap-draw-text x -1+yoff-b 1 orientation "b" dot-font fb 128
      yoff-c := CY-OFF[orientation]
      bitmap-draw-text x 64+yoff-c 1 orientation "c" dot-font fb 128
      bitmap-draw-text x -1+yoff-c 1 orientation "c" dot-font fb 128

  assert-all-same fb 0

  BX-OFF ::= [-1, 1, 2, 0]
  CX-OFF ::= [0, 2, 1, -1]

  64.repeat: | y |
    4.repeat: | orientation |
      xoff-b := BX-OFF[orientation]
      bitmap-draw-text 128+xoff-b y 1 orientation "b" dot-font fb 128
      bitmap-draw-text -1+xoff-b y 1 orientation "b" dot-font fb 128
      xoff-c := CX-OFF[orientation]
      bitmap-draw-text 128+xoff-c y 1 orientation "c" dot-font fb 128
      bitmap-draw-text -1+xoff-c y 1 orientation "c" dot-font fb 128

  assert-all-same fb 0

  XS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
         127, 126, 125, 124, 123, 122, 121, 120, 119, 118, 117, 116, 115, 114, 113, 112]

  YS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
         63, 62, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 51, 50, 49, 48]

  AX-OFF ::= [0, 1, 1, 0]
  AY-OFF ::= [1, 1, 0, 0]

  // Place the single pixel characters in all orientations all around the edges
  // of the frame buffer.
  XS.do: | x |
    YS.do: | y |
      bitmap-zap fb 0
      4.repeat: | orientation |
        sleep --ms=1
        ax := x + AX-OFF[orientation]
        ay := y + AY-OFF[orientation]
        bitmap-draw-text ax ay 1 orientation "a" dot-font fb 128
        if SLOW:
          expect-only-pixel-at fb x y
          bitmap-zap fb 0
        bitmap-rectangle x y 1 1 1 fb 128
        if SLOW:
          expect-only-pixel-at fb x y
          bitmap-zap fb 0
      4.repeat: | orientation |
        bx := x + BX-OFF[orientation]
        by := y + BY-OFF[orientation]
        bitmap-draw-text bx by 1 orientation "b" dot-font fb 128
        if SLOW:
          expect-only-pixel-at fb x y
          bitmap-zap fb 0
        cx := x + CX-OFF[orientation]
        cy := y + CY-OFF[orientation]
        bitmap-draw-text cx cy 1 orientation "c" dot-font fb 128
        if SLOW:
          expect-only-pixel-at fb x y
          bitmap-zap fb 0
      // All the above tests draw a pixel in the same place.  In fast mode we only
      // check once that a single pixel is set.
      if not SLOW:
        expect-only-pixel-at fb x y
      // Use the 9x9 block character.  This just checks for expects in the C++
      // code, it doesn't check that the result looks right.
      4.repeat: | orientation |
        bitmap-draw-text x y 1 orientation "d" dot-font fb 128

  bitmap-zap fb 0
  bitmap-rectangle -8 -8 1 9 9 fb 128
  expect-only-pixel-at fb 0 0
  bitmap-zap fb 0
  bitmap-rectangle -8 63 1 9 9 fb 128
  expect-only-pixel-at fb 0 63
  bitmap-zap fb 0
  bitmap-rectangle 127 63 1 9 9 fb 128
  expect-only-pixel-at fb 127 63
  bitmap-zap fb 0
  bitmap-rectangle 127 -8 1 9 9 fb 128
  expect-only-pixel-at fb 127 0

  // Use the 9x9 block character at the corners to place one pixel.
  bitmap-zap fb 0
  bitmap-draw-text -8 1 1 ORIENTATION-0 "d" dot-font fb 128
  expect-only-pixel-at fb 0 0
  bitmap-zap fb 0
  bitmap-draw-text -8 72 1 ORIENTATION-0 "d" dot-font fb 128
  expect-only-pixel-at fb 0 63
  bitmap-zap fb 0
  bitmap-draw-text 127 72 1 ORIENTATION-0 "d" dot-font fb 128
  expect-only-pixel-at fb 127 63
  bitmap-zap fb 0
  bitmap-draw-text 127 1 1 ORIENTATION-0 "d" dot-font fb 128
  expect-only-pixel-at fb 127 0

  bitmap-zap fb 0
  bitmap-draw-text 1 1 1 ORIENTATION-90 "d" dot-font fb 128
  expect-only-pixel-at fb 0 0
  bitmap-zap fb 0
  bitmap-draw-text 1 72 1 ORIENTATION-90 "d" dot-font fb 128
  expect-only-pixel-at fb 0 63
  bitmap-zap fb 0
  bitmap-draw-text 136 72 1 ORIENTATION-90 "d" dot-font fb 128
  expect-only-pixel-at fb 127 63
  bitmap-zap fb 0
  bitmap-draw-text 136 1 1 ORIENTATION-90 "d" dot-font fb 128
  expect-only-pixel-at fb 127 0

  bitmap-zap fb 0
  bitmap-draw-text 1 -8 1 ORIENTATION-180 "d" dot-font fb 128
  expect-only-pixel-at fb 0 0
  bitmap-zap fb 0
  bitmap-draw-text 1 63 1 ORIENTATION-180 "d" dot-font fb 128
  expect-only-pixel-at fb 0 63
  bitmap-zap fb 0
  bitmap-draw-text 136 63 1 ORIENTATION-180 "d" dot-font fb 128
  expect-only-pixel-at fb 127 63
  bitmap-zap fb 0
  bitmap-draw-text 136 -8 1 ORIENTATION-180 "d" dot-font fb 128
  expect-only-pixel-at fb 127 0

  bitmap-zap fb 0
  bitmap-draw-text -8 -8 1 ORIENTATION-270 "d" dot-font fb 128
  expect-only-pixel-at fb 0 0
  bitmap-zap fb 0
  bitmap-draw-text -8 63 1 ORIENTATION-270 "d" dot-font fb 128
  expect-only-pixel-at fb 0 63
  bitmap-zap fb 0
  bitmap-draw-text 127 63 1 ORIENTATION-270 "d" dot-font fb 128
  expect-only-pixel-at fb 127 63
  bitmap-zap fb 0
  bitmap-draw-text 127 -8 1 ORIENTATION-270 "d" dot-font fb 128
  expect-only-pixel-at fb 127 0

assert-all-same fb value:
  fb.size.repeat: assert: fb[it] == value

expect-only-pixel-at fb x y:
  non-zero-location := -1
  fb.size.repeat:
    byte := fb[it]
    if byte != 0:
      expect-equals -1 non-zero-location  // More than one non-zero pixel?!
      lowest-bit := byte & ~(byte - 1)
      expect-equals 0 (byte & ~lowest-bit)  // More than one bit in the byte?!
      non-zero-location = it
  expect non-zero-location != -1
  index := x + ((y >> 3) << 7)
  expect-equals (1 << (y & 7)) fb[index]

blur-get ba width x y:
  return ba[y * width + x]

blur-set ba width x y value:
  ba[y * width + x] = value

blur-gold ba width x-radius y-radius=x-radius:
  ba2 := ba.copy
  if x-radius == 0: x-radius = 1
  if y-radius == 0: y-radius = 1
  for y := 0; y < ba.size/width; y++:
    for x := x-radius - 1; x < width - (x-radius - 1); x++:
      sum := 0
      if x-radius < 2:
        sum = blur-get ba width x y
      else if x-radius == 2:
        sum += 1 * (blur-get ba width x - 1 y)
        sum += 2 * (blur-get ba width x + 0 y)
        sum += 1 * (blur-get ba width x + 1 y)
        sum >>= 2
      else if x-radius == 3:
        sum += 1 * (blur-get ba width x - 2 y)
        sum += 4 * (blur-get ba width x - 1 y)
        sum += 6 * (blur-get ba width x + 0 y)
        sum += 4 * (blur-get ba width x + 1 y)
        sum += 1 * (blur-get ba width x + 2 y)
        sum >>= 4
      blur-set ba2 width x y sum
  result := ba2.copy
  for x := 0; x < width; x++:
    for y := y-radius - 1; y < ba.size/width - (y-radius - 1); y++:
      sum := 0
      if y-radius < 2:
        sum = blur-get ba2 width x y
      else if y-radius == 2:
        sum += 1 * (blur-get ba2 width x y - 1)
        sum += 2 * (blur-get ba2 width x y + 0)
        sum += 1 * (blur-get ba2 width x y + 1)
        sum >>= 2
      else if y-radius == 3:
        sum += 1 * (blur-get ba2 width x y - 2)
        sum += 4 * (blur-get ba2 width x y - 1)
        sum += 6 * (blur-get ba2 width x y + 0)
        sum += 4 * (blur-get ba2 width x y + 1)
        sum += 1 * (blur-get ba2 width x y + 2)
        sum >>= 4
      blur-set result width x y sum
  return result

blur-compare ba ba2 width x-radius y-radius=x-radius:
  if x-radius < 1: x-radius = 1
  if y-radius < 1: y-radius = 1
  for x := x-radius - 1; x < width - (x-radius - 1); x++:
    for y := y-radius - 1; y < ba.size/width - (y-radius - 1); y++:
      if ba[x + y * width] != ba2[x + y * width]:
        print "Differ at $x $y $(x + y * width): $ba[x + y * width] vs $ba2[x + y * width]"
      expect-equals ba[x + y * width] ba2[x + y * width]

blur-log ba width:
  print ""
  for y := 0; y < ba.size/width; y++:
    line := ""
    for x := 0; x < width; x++:
      line += "$(%3d ba[x + y * width]) "
    print line

blur-test:
  if not bytemap-primitives-present:
    return
  ba := ByteArray 25
  ba[12] = 255
  gold := blur-gold ba 5 2
  bytemap-blur ba 5 2
  blur-compare ba gold 5 2

  ba = ByteArray 25
  13.repeat: ba[it] = 255
  gold = blur-gold ba 5 2
  bytemap-blur ba 5 2
  blur-compare ba gold 5 2

  ba = ByteArray 9
  ba[4] = 255
  gold = blur-gold ba 3 2
  bytemap-blur ba 3 2
  blur-compare ba gold 3 2

  ba = ByteArray 30
  30.repeat: ba[it] = (it * 17) & 0xff
  gold = blur-gold ba 6 2
  bytemap-blur ba 6 2
  blur-compare ba gold 6 2

  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur-gold ba 6 2
  bytemap-blur ba 6 2
  blur-compare ba gold 6 2

  ba = ByteArray 81
  ba[40] = 255
  gold = blur-gold ba 9 3
  bytemap-blur ba 9 3
  blur-compare ba gold 9 3

  // Zero blur.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur-gold ba 6 0
  bytemap-blur ba 6 0
  blur-compare ba gold 6 0

  // X blur 3.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur-gold ba 6 3 0
  bytemap-blur ba 6 3 0
  blur-compare ba gold 6 3 0

  // X blur 2.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur-gold ba 6 2 0
  bytemap-blur ba 6 2 0
  blur-compare ba gold 6 2 0

  // Y blur 3.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur-gold ba 6 0 3
  bytemap-blur ba 6 0 3
  blur-compare ba gold 6 0 3

  // Y blur 2.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur-gold ba 6 0 2
  bytemap-blur ba 6 0 2
  blur-compare ba gold 6 0 2

  // Asymmetric blur.
  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur-gold ba 6 2 3
  bytemap-blur ba 6 2 3
  blur-compare ba gold 6 2 3

  ba = ByteArray 30
  30.repeat: ba[it] = (it / 6) + (it % 6) > 3 ? 0 : 200
  gold = blur-gold ba 6 2 0
  bytemap-blur ba 6 2 0
  blur-compare ba gold 6 2 0

  ba = ByteArray 81
  ba[40] = 255
  gold = blur-gold ba 9 0 3
  bytemap-blur ba 9 0 3
  blur-compare ba gold 9 0 3

bytemap-test -> none:
  W ::= 42
  H ::= 17
  canvas := ByteArray (W * H)

  alien := ""
      + "__######__"
      + "__#O##O#__"
      + "_########_"
      + "_########_"
      + "__#_#__#__"
      + "__#_#__#__"

  ALIEN-WIDTH := 10

  expect-equals 0 canvas[0]

  bytemap-zap canvas ' '  // Set background to test transparency.

  // Plain copy to middle.
  // The x and y coordinates are the top left corner of the top left pixel of
  // the alien.
  bitmap-draw-bytemap 21 8  // x, y.
      --source=alien
      --source-width=ALIEN-WIDTH
      --destination=canvas
      --destination-width=W

  // Upside-down copy to middle.
  // The x and y coordinates are the top left corner of the top left pixel of
  // the unrotated alien, therefore at the bottom right corner of the bottom
  // right pixel of the area the alien covers on the canvas. So the corners
  // of this and the above just touch.
  bitmap-draw-bytemap 21 8  // x, y.
      --orientation=2       // 180 degrees.
      --source=alien
      --source-width=5      // Only the first 5 pixels of each line
      --source-line-stride=ALIEN-WIDTH
      --destination=canvas
      --destination-width=W

  // Bottom left corner to test clipping and transparency.
  bitmap-draw-bytemap -2 (H - 5)  // x, y.
      --transparent-index='_'     // Underscore is transparent.
      --source=alien
      --source-width=ALIEN-WIDTH
      --destination=canvas
      --destination-width=W

  PALETTE ::= ByteArray 384:
    if it / 3 == '#':
      '*'
    else if it / 3 == 'O':
      'o'
    else:
      it

  // Right edge, rotated.
  // The origin is at width - 6, so we can see 5 pixels of the alien.
  bitmap-draw-bytemap (W - 6) 14  // x, y.
      --transparent-index='_'     // Underscore is transparent.
      --orientation=1             // 90 degrees anticlockwise.
      --source=alien
      --source-width=ALIEN-WIDTH
      --palette=PALETTE
      --destination=canvas
      --destination-width=W

  // top right corner, rotated.
  bitmap-draw-bytemap (W + 2) 3  // x, y.
      --transparent-index='_'    // Underscore is transparent.
      --orientation=2            // 180 degrees.
      --source=alien
      --source-width=ALIEN-WIDTH
      --destination=canvas
      --destination-width=W

  ALPHA ::= ByteArray 128:
    it == '_' ?  0 : 255

  // Top left corner, rotated right.
  bitmap-draw-bytemap 3 -2  // x, y.
      --alpha=ALPHA
      --orientation=3       // 270 degrees anticlockwise.
      --source=alien
      --source-width=ALIEN-WIDTH
      --destination=canvas
      --destination-width=W

  W.repeat:
    char := '0' + it % 10
    canvas[it + (H - 1) * W] = char
  H.repeat:
    char := '0' + it % 10
    canvas[it * W + W - 2] = char
  bytemap-rectangle (W - 1) 0 '\n' 1 H canvas W

  EXPECTED ::= """
      ###                                #####0
      #O#                                 #O##1
      ###             #_#__               ####2
      ###             #_#__                   3
      #O#             ####_                   4
      ###             ####_                 **5
      #               #O#__               ****6
                      ###__               *o**7
                           __######__     ****8
                           __#O##O#__     ****9
                           _########_     *o**0
                           _########_     ****1
      ######               __#_#__#__       **2
      #O##O#               __#_#__#__         3
      #######                                 4
      #######                                 5
      01234567890123456789012345678901234567896
      """

  expect-equals EXPECTED canvas.to-string


io-data-test:
  if not bitmap-primitives-present: return

  W ::= 10
  H ::= 6
  canvas := ByteArray (W * H)

  alien := ""
      + "__######__"
      + "__#O##O#__"
      + "_########_"
      + "_########_"
      + "__#_#__#__"
      + "__#_#__#__"

  fake-alien := FakeData alien.to-byte-array

  ALIEN-WIDTH := 10

  expect-equals 0 canvas[0]

  bytemap-zap canvas ' '  // Set background to test transparency.

  // Plain copy.
  // The x and y coordinates are the top left corner of the top left pixel of
  // the alien.
  bitmap-draw-bytemap 0 0  // x, y.
      -1   // No transparency.
      0    // No rotation.
      fake-alien
      ALIEN-WIDTH
      #[]  // No palette.
      canvas
      W

  expect-equals alien canvas.to-string

  ba := #[1, 2, 3, 4]

  // Check mask works.
  blit (FakeData ba) ba 4 --mask=0xfe
  ba.size.repeat:
    expect-equals [0, 2, 2, 4][it] ba[it]

composit-test -> none:
  if bytemap-primitives-present:
    composit-test-bytemap
  if bitmap-primitives-present:
    composit-test-bitmap

composit-test-bytemap -> none:
  canvas := ByteArray 16
  frame := ByteArray 16: 42
  frame-opacity := #[128, 128, 128, 128,
                     128,   0,   0, 128,
                     128,   0,   0, 128,
                     128, 128, 128, 128,
                    ]
  painting := #[1, 2, 3, 4,
                5, 6, 7, 8,
                9, 0, 1, 2,
                3, 4, 5, 6,
               ]
  painting-opacity := #[  0,   0,   0, 128,
                          0,   0, 128, 255,
                          0, 128, 255, 255,
                        128, 255, 255, 255,
                       ]

  BYTE-MODE ::= false

  composit-bytes canvas frame-opacity frame painting-opacity painting BYTE-MODE

  EXPECTED1 := #[0x15, 0x15, 0x15, 0x0c,
                 0x15,    0,    3,    8,
                 0x15,    0,    1,    2,
                 0x0c,    4,    5,    6,
                ]
  expect-equals EXPECTED1 canvas

  // Fully transparent frame means we can pass null for the frame bitmap.
  composit-bytes canvas #[0] null painting-opacity painting BYTE-MODE
  EXPECTED2 := #[0x15, 0x15, 0x15,    8,
                 0x15,    0,    5,    8,
                 0x15,    0,    1,    2,
                    7,    4,    5,    6,
                ]
  expect-equals EXPECTED2 canvas

  // Fully opaque frame can be done with #[0xff] for the opacity.
  composit-bytes canvas #[0xff] frame painting-opacity painting BYTE-MODE
  EXPECTED3 := #[42,     42,   42, 0x17,
                 42,     42, 0x18,    8,
                 42,   0x15,    1,    2,
                 0x16,    4,    5,    6,
                ]
  expect-equals EXPECTED3 canvas

  // Fully opaque painting can be done with #[0xff] for the opacity.
  composit-bytes canvas frame-opacity frame #[0xff] painting BYTE-MODE
  expect-equals painting canvas

  // Fully opaque frame and fully transparent painting.
  composit-bytes canvas #[0xff] frame #[0] painting BYTE-MODE
  expect-equals frame canvas

composit-test-bitmap -> none:
  // The canvas is a bitmap that is 4x32 pixels.
  canvas := ByteArray 16
  frame := ByteArray 16: 42
  frame-opacity := #[255, 128, 128, 255,
                     255,   0,   0, 255,
                     255,   0,   0, 255,
                     255,   1,   1, 255,
                    ]
  painting := #[1, 2, 3, 4,
                5, 6, 7, 8,
                9, 0, 1, 2,
                3, 4, 5, 6,
               ]
  painting-opacity := #[  0,   0,   0, 255,
                          0,   0, 255, 255,
                          0, 255, 255, 255,
                        255, 255, 255, 255,
                       ]

  BIT-MODE ::= true

  composit-bytes canvas frame-opacity frame painting-opacity painting BIT-MODE

  EXPECTED1 := #[42, 0, 0, 4,
                 42, 0, 7, 8,
                 42, 0, 1, 2,
                  3, 4, 5, 6,
                ]
  expect-equals EXPECTED1 canvas

  // Fully transparent frame means we can pass null for the frame bitmap.
  composit-bytes canvas #[0] null painting-opacity painting BIT-MODE
  EXPECTED2 := #[42, 0, 0, 4,
                 42, 0, 7, 8,
                 42, 0, 1, 2,
                  3, 4, 5, 6,
                ]
  expect-equals EXPECTED2 canvas

  // Fully opaque frame can be done with #[0xff] for the opacity.
  composit-bytes canvas #[0xff] frame painting-opacity painting BIT-MODE
  EXPECTED3 := #[42, 42, 42, 4,
                 42, 42,  7, 8,
                 42,  0,  1, 2,
                  3,  4,  5, 6,
                ]
  expect-equals EXPECTED3 canvas

  // Fully opaque painting can be done with #[0xff] for the opacity.
  composit-bytes canvas frame-opacity frame #[0xff] painting BIT-MODE
  expect-equals painting canvas

  // Fully opaque frame and fully transparent painting.
  composit-bytes canvas #[0xff] frame #[0] painting BIT-MODE
  expect-equals frame canvas
