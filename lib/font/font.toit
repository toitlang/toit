// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

class Font:
  proxy_ := ?
  hash-code / int ::= hash-code-counter_++

  static hash-code-counter_ := 1234

  proxy: return proxy_

  constructor.get font-name/string:
    proxy_ = font-get_ resource-freeing-module_ font-name
    add-finalizer this:: this.finalize_

  /**
  Constructs a font with support for selected Unicode blocks.
  $unicode-blocks is a list of arrays with byte data, each describing a
    Unicode block.
  */
  constructor unicode-blocks/List:
    // The primitive takes a small array (not a list) of byte arrays, so we
    // convert to that.
    array := Array_.from unicode-blocks
    proxy_ = font-get-nonbuiltin_ resource-freeing-module_ array
    add-finalizer this:: this.finalize_

  /**
  Constructs a font with support for a single range of Unicode code points.
  $glyph-byte-data is a list of byte data, describing a set of glyphs in a
    range.  This is used by the icon code.  All icons are in the private use
    Unicode block, but we don't have a single ByteArray for the whole block,
    since that would be huge.
  */
  constructor.from-page_ glyph-byte-data/ByteArray:
    // The primitive takes a small array (not a list) of byte arrays, so we
    // convert to that.
    array := create-array_ glyph-byte-data
    proxy_ = font-get-nonbuiltin_ resource-freeing-module_ array
    add-finalizer this:: this.finalize_

  /**
  The bounding box of the given string $str in this font.
  Returns [width, height, x-offset, y-offset].
  */
  text-extent str/string from/int=0 to/int=str.size:
    result := Array_ 4
    font-get-text-size_ str[from..to] proxy_ result
    return result

  /**
  The pixel width of the given string $str in this font.
  Note that when you actually draw the text it may go a few pixels to the left
    of the origin or to the right of x origin + pixel-width.  See text_extent.
  */
  pixel-width str/string from/int=0 to/int=str.size -> int:
    return font-get-text-size_ str[from..to] proxy_ (Array_ 0)

  /**
  Checks whether a font has a glyph for a given Unicode code point.
  */
  contains character/int -> bool:
    return font-contains_ proxy_ character

  close:
    if proxy_:
      remove-finalizer this
      font-delete_ proxy_
      proxy_ = null

  finalize_:
    if proxy_:
      font-delete_ proxy_

font-get_ module font-name:
  #primitive.font.get-font

font-get-nonbuiltin_ module font-blocks/Array_:
  #primitive.font.get-nonbuiltin

font-delete_ font:
  #primitive.font.delete-font

font-contains_ font code-point/int:
  #primitive.font.contains

// Get the size of a text in the given font.  The result argument is a
// 4-element array which is used to return the bounding box (width, height,
// x-offset, y-offset) of the text.  The offsets are relative to the text
// origin used in text drawing operations, which is normally the bottom left of
// the first character.
font-get-text-size_ str font result:
  #primitive.font.get-text-size
