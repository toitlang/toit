// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .io as io

/**
Low level operations for manipulating byte arrays as images.
*/

ORIENTATION-0 ::= 0
ORIENTATION-90 ::= 1
ORIENTATION-180 ::= 2
ORIENTATION-270 ::= 3

/**
Draws a text on a frame buffer.
$x, $y is the bottom left of the text.
$color is 0 or 1.
The $orientation is 0, 1, 2, 3 for 90 degree increments, anticlockwise.

The text may be wholly or partially outside the area of the byte array.  The drawn
  text will be clipped.
The assumed pixel layout is the one used by the SSD1306 display.
  (From top to bottom, each 8-tall strip of pixels is represented by
  $byte-array-width bytes, where the least significant bit is at the
  top.)
*/
bitmap-draw-text x/int y/int color/int orientation/int text/string font byte-array/ByteArray byte-array-width/int:
  // Extract the proxy from the font class and forward.
  bitmap-draw-text_ x y color orientation text font.proxy byte-array byte-array-width

bitmap-draw-text_ x y color orientation text font-proxy byte-array byte-array-width:
  #primitive.bitmap.draw-text

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
bytemap-draw-text x/int y/int color/int orientation/int text/string font byte-array/ByteArray byte-array-width/int:
  // Extract the proxy from the font class and forward.
  bytemap-draw-text_ x y color orientation text font.proxy byte-array byte-array-width

bytemap-draw-text_ x y color orientation text font-proxy byte-array byte-array-width:
  #primitive.bitmap.byte-draw-text

/**
Draws a bitmap on a frame buffer.  Any one-bits in the source are drawn
  with the given color, while the zero-bits are left unchanged.
$x, $y are the top left of the bitmap.
$color is the color to draw with in the $destination, normally 0 or 1.
The $orientation is 0, 1, 2, 3 for 90 degree increments, anticlockwise.
  See $ORIENTATION-0, $ORIENTATION-90, $ORIENTATION-180, $ORIENTATION-270.
The coordinates may be wholly or partially outside the area of the byte array.
  The drawn bitmap will be clipped.
The assumed pixel layout for both source and destination is rows from top to
  bottom.  Within each row pixels are arranged from left to right.  Within
  each byte the most significant bit is the leftmost pixel.
The $source-width is in pixels.
The $source-line-stride is in bytes and may be more than the rounded byte count
  corresponding to the source width.  In this case some bytes are ignored at
  the end of each source row.  If unspecified, the source line stride is set
  to the lowest number of whole bytes corresponding to the source width.
The height of the source bitmap is inferred from the size of the $source.
If $bytewise is true then the destination is one byte per pixel rather than
  one bit per pixel.  In this case the $color may be in the range 0-255.
*/
bitmap-draw-bitmap x /int y /int -> none
    --color/int
    --orientation/int = 0
    --source  // io.Data.
    --source-width/int
    --source-line-stride/int=((source-width + 7) >> 3)
    --destination/ByteArray
    --destination-width/int
    --bytewise/bool=false:
  bitmap-draw-bitmap_ x y color orientation source 0 source-width source-line-stride destination destination-width bytewise

/**
Older version of bitmap-draw-bitmap.
*/
bitmap-draw-bitmap x /int y /int -> none
    color /int
    orientation /int
    source /io.Data
    source-offset /int
    source-width /int
    byte-array /ByteArray
    byte-array-width /int
    bytewise /bool:
  source-line-stride := (source-width + 7) >> 3
  bitmap-draw-bitmap_ x y color orientation source source-offset source-width source-line-stride byte-array byte-array-width bytewise

bitmap-draw-bitmap_ x y color orientation source source-offset source-width source-line-stride destination destination-width bytewise -> none:
  #primitive.bitmap.draw-bitmap: | error |
    io.primitive-redo-io-data_ error source: | bytes-source |
      bitmap-draw-bitmap x y color orientation bytes-source \
          source-offset source-width destination destination-width bytewise

/**
Draws an indexed bytemap on a byte-oriented frame buffer.
$x, $y is the top left of the source bytemap.
The $source is a byte array of indexes into the $palette, or a byte array of
  pixel values if no palette is specified.
The $transparent-index is an integer between 0 and 255, or -1 (the default) to
  indicate no color is transparent.  This corresponds to the way transparency
  is specified in a GIF file.  Alternatively, $alpha can be a byte array of
  alpha values.  Any index that is beyond the end of the byte array will be
  treated as fully opaque.  This corresponds to the transparency info in an
  indexed PNG file.
The $orientation is 0, 1, 2, 3 for 90 degree increments, anticlockwise.
  See $ORIENTATION-0, $ORIENTATION-90, $ORIENTATION-180, $ORIENTATION-270.
The $palette is a byte array where every third byte is used to look up
  values from the source array.  This corresponds to the layout of a
  palette in an indexed PNG file.  If the palette is too short, indexes
  above the palette index are treated as having a 1:1 mapping.
The drawing location may be wholly or partially outside the area of the byte
  array.  The drawn bitmap will be clipped.
The assumed pixel layout for both source and destination is rows from top to
  bottom.  Within each row, pixels are arranged from left to right, one
  byte per pixel.
The $source-line-stride may be more than the $source-width, in which case
  some bytes are ignored at the end of each source row.
The height of the source bytemap is inferred from the size of the $source.
*/
bitmap-draw-bytemap x/int y/int -> none
    --transparent-index/int=-1
    --alpha/ByteArray?=null
    --orientation/int=0
    --source  // io.Data.
    --source-width/int
    --source-line-stride/int=source-width
    --palette/ByteArray=#[]
    --destination/ByteArray
    --destination-width/int:
  if transparent-index >= 0 and alpha: throw "Specified both alpha and transparent-index"
  transparent := alpha or transparent-index
  bitmap-draw-bytemap_ x y transparent orientation source source-width source-line-stride palette destination destination-width

/// Older version of bitmap-draw-bytemap.
bitmap-draw-bytemap x /int y /int -> none
    transparent-color
    orientation /int
    source /io.Data
    source-width /int
    palette /ByteArray
    destination-array /ByteArray
    destination-width /int:
  bitmap-draw-bytemap_ x y transparent-color orientation source source-width source-width palette destination-array destination-width

bitmap-draw-bytemap_ x y transparent-color orientation source source-width source-line-stride palette destination-array destination-width -> none:
  #primitive.bitmap.draw-bytemap: | error |
    io.primitive-redo-io-data_ error source: | bytes-source |
      bitmap-draw-bytemap x y transparent-color orientation bytes-source \
          source-width palette destination-array destination-width

/// Fills a frame buffer with a single color (0: black, 1: white)
bitmap-zap byte-array/ByteArray color/int:
  bytemap-zap byte-array (color == 0 ? 0 : 0xff)

/// Fills a frame buffer with a single color
bytemap-zap byte-array/ByteArray color/int:
  #primitive.bitmap.byte-zap

OVERWRITE ::= 0
OR ::= 1
ADD ::= 2
ADD-16-LE ::= 3
AND ::= 4
XOR ::= 5

/**
Copies a rectangle of pixels from one byte array to another.
See a high level explanation at https://docs.toit.io/language/sdk/blit
For each pixel reads a single byte from the source, puts it through the lookup
  table, rolls it $shift bits to the right, 'ands' it with the $mask, then applies
  it to the destination, using $operation.
$operation is one of $OVERWRITE, $OR, $AND, $XOR, $ADD, or $ADD-16-LE.  The first
  five perform the operation `dest-byte = new-byte`, `dest-byte |= new-byte`,
  `dest-byte &= new-byte`, `dest-byte ^= new-byte`, and `dest-byte += new-byte`
  respectively, where the addition is saturating and unsigned 8 bit, clamped to
  0xff.  $ADD-16-LE treats the destination and the subsequent byte as a
  little-endian 16 bit integer, and does a saturating 16 bit addition, clamped
  to 0xffff.
Negative $shift distances are allowed and roll the value left instead of right.
  Any bits rolled out of the byte reappear at the other end.  A shift value of
  4 will thus swap the nibbles in a byte.  Combine with a mask to get shift
  operations that insert zeros like a conventional unsigned shift.
Defaults are an identity $lookup-table, a $shift of 0, a $mask of 0xff, and an
  $operation of OVERWRITE, resulting in a pure copying operation that does not
  modify the bytes.
For both the source and destination we can define how many bytes to skip per
  pixel and per line when stepping in the x and y directions.  The number of
  lines in the rectangle is determined by the size of the smaller of the source
  and destination data.  All stride values must be non-negative, with the exception
  of $destination-pixel-stride, which can be negative to facilitate reversing of
  image lines.  Negative pixel strides are not allowed with $operation == $ADD-16-LE.
  In the case of a negative pixel stride we start each line at the highest index,
  rather than the lowest.

# Examples
```
  // Byte-swap the 16 bit values in byte-array from little-endian
  // to big-endian (or vice versa).
  tmp := ByteArray byte-array.size
  blit byte-array tmp[1..] byte-array.size / 2 --source-pixel-stride=2 --destination-pixel-stride=2
  blit byte-array[1..] tmp byte-array.size / 2 --source-pixel-stride=2 --destination-pixel-stride=2
  byte-array.replace 0 tmp

  // Take three byte-arrays of red, green, and blue pixels, and create a
  // single byte-array with the pixels interleaved in r, g, b order.
  output := ByteArray red.size * 3
  blit red   output      red.size --destination-pixel-stride=3
  blit green output[1..] red.size --destination-pixel-stride=3
  blit blue  output[2..] red.size --destination-pixel-stride=3

  // Extract the red pixels from a 30x20 square in a 100x100 rgb-interleaved 24
  // bit image at position (42,13)
  x := 42
  y := 13
  w := 30
  h := 20
  red-extract := ByteArray: w * h
  first-pixel := (x + 100 * y) * 3
  blit image[first-pixel..] red-extract w --source-pixel-stride=3 --source-line-stride=300
```
*/
blit source/io.Data destination/ByteArray pixels-per-line/int -> none
    --source-pixel-stride=1
    --source-line-stride=(pixels-per-line * source-pixel-stride)
    --destination-pixel-stride=1
    --destination-line-stride=(pixels-per-line * destination-pixel-stride.abs)
    --lookup-table/ByteArray?=null
    --shift=0
    --mask=0xff
    --operation=OVERWRITE:
  blit_ destination destination-pixel-stride destination-line-stride source source-pixel-stride source-line-stride pixels-per-line lookup-table shift mask operation

blit_ destination destination-pixel-stride destination-line-stride source source-pixel-stride source-line-stride pixels-per-line lookup-table shift mask operation -> none:
  #primitive.bitmap.blit: | error |
    io.primitive-redo-io-data_ error source: | bytes-source |
      blit_ destination destination-pixel-stride destination-line-stride bytes-source \
          source-pixel-stride source-line-stride pixels-per-line lookup-table shift mask operation

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
reverse byte-array/ByteArray -> none:
  lut byte-array byte-array REVERSED

ROT13 ::= ByteArray 0x100:
  result := it
  if      'n' <= it <= 'z' or 'N' <= it <= 'Z': result -= 13
  else if 'a' <= it <= 'm' or 'A' <= it <= 'M': result += 13
  result  // Final value in the block is used to initialize the ByteArray.

/// Rot13 encode/decode a string.
rot13 str/string -> string:
  byte-array := ByteArray: str.size
  lut byte-array str ROT13
  return byte-array.to-string
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
  $byte-array-width bytes, where the least significant bit is at the
  top.)
The rectangle may be wholly or partially outside the area of the byte array.  The
  drawn rectangle will be clipped.
Returns true if something was drawn, or false if the entire rectangle was
  clipped away.
*/
bitmap-rectangle x/int y/int color/int width/int height/int byte-array/ByteArray byte-array-width/int:
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
bytemap-rectangle x/int y/int color/int w/int h/int byte-array/ByteArray byte-array-width/int:
  #primitive.bitmap.byte-rectangle

/**
Paints a framed window $frame on top of a background that has already been
  rendered.  The $frame can be partially transparent and so can the window
  contents.  The $frame is painted on top of the background, then window
  contents are painted on top.
*/
composit-bytes dest/ByteArray frame-opacity/ByteArray frame/ByteArray?
    painting-opacity/ByteArray painting/ByteArray bits-not-bytes/bool:
  #primitive.bitmap.composit

/**
Performs Gaussian blur on the bytes of the byte array.
The pixel layout is one byte per pixel in lines from top to bottom.  Each line
  is arranged from left to right.
*/
bytemap-blur byte-array/ByteArray width/int x-blur-radius/int y-blur-radius/int=x-blur-radius:
  #primitive.bitmap.bytemap-blur
