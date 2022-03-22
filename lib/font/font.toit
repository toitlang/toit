// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

class Font:
  proxy_ := ?
  hash_code / int

  static hash_code_counter_ := 1234

  proxy: return proxy_

  constructor.get font_name/string:
    proxy_ = font_get_ resource_freeing_module_ font_name
    hash_code = hash_code_counter_++
    add_finalizer this:: this.finalize_

  /**
  Deprecated, use the unnamed constructor instead.
  */
  constructor.from_pages unicode_blocks/List:
    return Font unicode_blocks

  /**
  Constructs a font with support for selected Unicode blocks.
  $unicode_blocks is a list of arrays with byte data, each describing a
    Unicode block.
  */
  constructor unicode_blocks/List:
    // The primitive takes a small array (not a list) of byte arrays, so we
    // convert to that.
    array := Array_.from unicode_blocks
    hash_code = hash_code_counter_++
    proxy_ = font_get_nonbuiltin_ resource_freeing_module_ array
    add_finalizer this:: this.finalize_

  /**
  Constructs a font with support for a single range of Unicode code points.
  $glyph_byte_data is a list of byte data, describing a set of glyphs in a
    range.  This is used by the icon code.  All icons are in the private use
    Unicode block, but we don't have a single ByteArray for the whole block,
    since that would be huge.
  */
  constructor.from_page_ glyph_byte_data/ByteArray:
    // The primitive takes a small array (not a list) of byte arrays, so we
    // convert to that.
    array := create_array_ glyph_byte_data
    hash_code = hash_code_counter_++
    proxy_ = font_get_nonbuiltin_ resource_freeing_module_ array
    add_finalizer this:: this.finalize_

  /**
  The bounding box of the given string $str in this font.
  Returns [width, height, x-offset, y-offset].
  */
  text_extent str/string from/int=0 to/int=str.size:
    result := Array_ 4
    font_get_text_size_ str[from..to] proxy_ result
    return result

  /**
  The pixel width of the given string $str in this font.
  Note that when you actually draw the text it may go a few pixels to the left
    of the origin or to the right of x origin + pixel_width.  See text_extent.
  */
  pixel_width str/string from/int=0 to/int=str.size -> int:
    return font_get_text_size_ str[from..to] proxy_ (Array_ 0)

  /**
  Checks whether a font has a glyph for a given Unicode code point.
  */
  contains character/int -> bool:
    return font_contains_ proxy_ character

  close:
    if proxy_:
      remove_finalizer this
      font_delete_ proxy_
      proxy_ = null

  finalize_:
    if proxy_:
      font_delete_ proxy_

/// Deprecated. Use $Font.get instead.
font_get font_name:
  return Font.get font_name

font_get_ module font_name:
  #primitive.font.get_font

font_get_nonbuiltin_ module font_blocks/Array_:
  #primitive.font.get_nonbuiltin

font_delete_ font:
  #primitive.font.delete_font

font_contains_ font code_point/int:
  #primitive.font.contains

// Get the size of a text in the given font.  The result argument is a
// 4-element array which is used to return the bounding box (width, height,
// x-offset, y-offset) of the text.  The offsets are relative to the text
// origin used in text drawing operations, which is normally the bottom left of
// the first character.
font_get_text_size_ str font result:
  #primitive.font.get_text_size
