// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Low level operations for manipulating byte arrays as images.
*/

ORIENTATION_0 ::= 0
ORIENTATION_90 ::= 1
ORIENTATION_180 ::= 2
ORIENTATION_270 ::= 3

/**
Draws a text on a frame buffer.
$x, $y is the bottom left of the text.
$color is 0 or 1.
The $orientation is 0, 1, 2, 3 for 90 degree increments, anticlockwise.

The text may be wholly or partially outside the area of the byte array.  The drawn
  text will be clipped.
The assumed pixel layout is the one used by the SSD1306 display.
  (From top to bottom, each 8-tall strip of pixels is represented by
  $byte_array_width bytes, where the least significant bit is at the
  top.)
*/
bitmap_draw_text x/int y/int color/int orientation/int text/string font byte_array/ByteArray byte_array_width/int:
  // Extract the proxy from the font class and forward.
  bitmap_draw_text_ x y color orientation text font.proxy byte_array byte_array_width

bitmap_draw_text_ x y color orientation text font_proxy byte_array byte_array_width:
  #primitive.bitmap.draw_text

/**
Draws a text on a frame buffer.
$x, $y is the bottom left of the text.
$color is 0 or 1.
The $orientation is 0, 1, 2, 3 for 90 degree increments, anticlockwise.

The text may be wholly or partially outside the area of the byte array.  The drawn
  text will be clipped.
The pixel layout is one byte per pixel in lines from top to bottom.  Each line
  is arranged from left to right.
*/
bytemap_draw_text x/int y/int color/int orientation/int text/string font byte_array/ByteArray byte_array_width/int:
  // Extract the proxy from the font class and forward.
  bytemap_draw_text_ x y color orientation text font.proxy byte_array byte_array_width

bytemap_draw_text_ x y color orientation text font_proxy byte_array byte_array_width:
  #primitive.bitmap.byte_draw_text

/**
Draws a bitmap on a frame buffer.
$x, $y is the top left of the bitmap.
$color is 0 or 1.
The $orientation is 0, 1, 2, 3 for 90 degree increments, anticlockwise.

The bitmap may be wholly or partially outside the area of the byte array.  The drawn
  bitmap will be clipped.
The assumed pixel layout is the one used by the SSD1306 display.
  (From top to bottom, each 8-tall strip of pixels is represented by
  $byte_array_width bytes, where the least significant bit is at the
  top.)
*/
bitmap_draw_bitmap ->none
    x /int
    y /int
    color /int
    orientation /int
    source_array
    byte_array_offset /int
    source_width /int
    byte_array /ByteArray
    byte_array_width /int
    bytewise /bool:
  #primitive.bitmap.draw_bitmap

/**
Draws an indexed bytemap on a byte-oriented frame buffer.
$x, $y is the top left of the source bytemap.
$transparent_color is between 0 and 255, or -1 to indicate no color is
  transparent.
The $orientation is 0, 1, 2, 3 for 90 degree increments, anticlockwise.
The $palette is a byte array where every third byte is used to look up
  values from the source array.
The source may be wholly or partially outside the area of the byte array.  The drawn
  bitmap will be clipped.
The assumed pixel layout for both input and output is rows from top to
  bottom.  Within each row pixels are arranged from left to right, one
  byte per pixel.
*/
bitmap_draw_bytemap -> none
    x /int
    y /int
    transparent_color /int
    orientation /int
    source_array
    source_width /int
    palette /ByteArray
    destination_array /ByteArray
    destination_width /int:
  #primitive.bitmap.draw_bytemap

/// Fills a frame buffer with a single color (0: black, 1: white)
bitmap_zap byte_array color:
  bytemap_zap byte_array (color == 0 ? 0 : 0xff)

/// Fills a frame buffer with a single color
bytemap_zap byte_array color:
  #primitive.bitmap.byte_zap

IDENTITY_LOOKUP_TABLE ::= ByteArray 0x100: it

OVERWRITE ::= 0
OR ::= 1
ADD ::= 2
ADD_16_LE ::= 3
AND ::= 4
XOR ::= 5

/**
Copies a rectangle of pixels from one byte array to another.
See a high level explanation at https://docs.toit.io/language/sdk/blit
For each pixel reads a single byte from the source, puts it through the lookup
  table, rolls it $shift bits to the right, 'ands' it with the $mask, then applies
  it to the destination, using $operation.
$operation is one of $OVERWRITE, $OR, $AND, $XOR, $ADD, or $ADD_16_LE.  The first
  five perform the operation dest_byte = new_byte, dest_byte |= new_byte,
  dest_byte &= new_byte, dest_byte ^= new_byte, and dest_byte += new_byte
  respectively, where the addition is saturating and unsigned 8 bit, clamped to
  0xff.  $ADD_16_LE treats the destination and the subsequent byte as a
  little-endian 16 bit integer, and does a saturating 16 bit addition, clamped
  to 0xffff.
Negative $shift distances are allowed and roll the value left instead of right.
  Any bits rolled out of the byte reappear at the other end.  A shift value of
  4 will thus swap the nibbles in a byte.  Combine with a mask to get shift
  operations that insert zeros like a conventional unsigned shift.
Defaults are an identity $lookup_table, a $shift of 0, a $mask of 0xff, and an
  $operation of OVERWRITE, resulting in a pure copying operation that does not
  modify the bytes.
For both the source and destination we can define how many bytes to skip per
  pixel and per line when stepping in the x and y directions.  The number of
  lines in the rectangle is determined by the size of the smaller of the source
  and destination data.  All stride values must be non-negative, with the exception
  of $destination_pixel_stride, which can be negative to facilitate reversing of
  image lines.  Negative pixel strides are not allowed with $operation == $ADD_16_LE.
  In the case of a negative pixel stride we start each line at the highest index,
  rather than the lowest.

# Examples
```
  // Byte-swap the 16 bit values in byte_array from little-endian
  // to big-endian (or vice versa).
  tmp := ByteArray byte_array.size
  blit byte_array tmp[1..] byte_array.size / 2 --source_pixel_stride=2 --destination_pixel_stride=2
  blit byte_array[1..] tmp byte_array.size / 2 --source_pixel_stride=2 --destination_pixel_stride=2
  byte_array.replace 0 tmp

  // Take three byte_arrays of red, green, and blue pixels, and create a
  // single byte_array with the pixels interleaved in r, g, b order.
  output := ByteArray red.size * 3
  blit red   output      red.size --destination_pixel_stride=3
  blit green output[1..] red.size --destination_pixel_stride=3
  blit blue  output[2..] red.size --destination_pixel_stride=3

  // Extract the red pixels from a 30x20 square in a 100x100 rgb-interleaved 24
  // bit image at position (42,13)
  x := 42
  y := 13
  w := 30
  h := 20
  red_extract := ByteArray: w * h
  first_pixel := (x + 100 * y) * 3
  blit image[first_pixel..] red_extract w --source_pixel_stride=3 --source_line_stride=300
```
*/
blit source destination/ByteArray pixels_per_line/int
    --source_pixel_stride=1 --source_line_stride=(pixels_per_line * source_pixel_stride)
    --destination_pixel_stride=1 --destination_line_stride=(pixels_per_line * destination_pixel_stride.abs)
    --lookup_table/ByteArray=IDENTITY_LOOKUP_TABLE
    --shift=0
    --mask=0xff
    --operation=OVERWRITE:
  blit_ destination destination_pixel_stride destination_line_stride source source_pixel_stride source_line_stride pixels_per_line lookup_table shift mask operation

blit_ destination destination_pixel_stride destination_line_stride source source_pixel_stride source_line_stride pixels_per_line lookup_table shift mask operation:
  #primitive.bitmap.blit

/**
Transform a ByteArray in-place, using a 256-entry look-up table.
# Examples
```
REVERSED ::= ByteArray 0x100: 0
  | (it & 0x01) << 7
  | (it & 0x02) << 5
  | (it & 0x04) << 3
  | (it & 0x08) << 1
  | (it & 0x10) >> 1
  | (it & 0x20) >> 3
  | (it & 0x40) >> 5
  | (it & 0x80) >> 7
/// Reverse the bits in each byte.
reverse byte_array/ByteArray -> none:
  lut byte_array byte_array REVERSED

ROT13 ::= ByteArray 0x100:
  result := it
  if      'n' <= it <= 'z' or 'N' <= it <= 'Z': result -= 13
  else if 'a' <= it <= 'm' or 'A' <= it <= 'M': result += 13
  result  // Final value in the block is used to initialize the ByteArray.

/// Rot13 encode/decode a string.
rot13 str/string -> string:
  byte_array := ByteArray: str.size
  lut byte_array str ROT13
  return byte_array.to_string
```
*/
lut source/ByteArray destination/ByteArray table/ByteArray -> none:
  length := min source.size destination.size
  blit_ destination 1 length source 1 length length table 0 0xff OVERWRITE

/**
Draws a rectangle of 0s or 1s on the byte array.
$x, $y is the top left of the rectangle.
$color is 0 or 1.

The assumed pixel layout is the one used by the SSD1306 display.
  (From top to bottom, each 8-tall strip of pixels is represented by
  $byte_array_width bytes, where the least significant bit is at the
  top.)
The rectangle may be wholly or partially outside the area of the byte array.  The
  drawn rectangle will be clipped.
Returns true if something was drawn, or false if the entire rectangle was
  clipped away.
*/
bitmap_rectangle x y color width height byte_array byte_array_width:
  #primitive.bitmap.rectangle

/**
Draws a rectangle of bytes on the byte array.
$x, $y is the top left of the rectangle.
$color is between 0 and 255.

The rectangle may be wholly or partially outside the area of the byte array.  The
  drawn rectangle will be clipped.
The pixel layout is one byte per pixel in lines from top to bottom.  Each line
  is arranged from left to right.
Returns true if something was drawn, or false if the entire rectangle was
  clipped away.
*/
bytemap_rectangle x y color w h byte_array byte_array_width:
  #primitive.bitmap.byte_rectangle

composit_bytes dest frame_opacity frame painting_opacity painting bits_not_bytes:
  #primitive.bitmap.composit

/**
Performs Gaussian blur on the bytes of the byte array.
The pixel layout is one byte per pixel in lines from top to bottom.  Each line
  is arranged from left to right.
*/
bytemap_blur byte_array width x_blur_radius y_blur_radius=x_blur_radius:
  #primitive.bitmap.bytemap_blur
