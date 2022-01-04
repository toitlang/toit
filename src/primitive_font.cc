// Copyright (C) 2018 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// Support for bitmapped Unicode fonts.

#include "process.h"
#include "objects.h"
#include "objects_inline.h"
#include "primitive_font.h"
#include "primitive.h"
#include "sha256.h"

namespace toit {

// File format for FontBlock: A block of Unicode in a particular font.
//  0-4  Magic number 0x7017f097 or 0x7017f096 for the version without checksum.
//  4-7  Length in bytes including magic number, length field and terminating 0xff.
//  8-39 Sha256 checksum, checks everything after this point incl. terminating 0xff.
//       A number of records, consisting of a signed 1-byte key, and a value.
//       Keys 0 to 127:   A 3-byte little-endian value follows.
//       Keys -128 to -1: A null terminated string value follows.
//  Known keys:
//    'f'    from      Lowest code point.
//    't'    to        Highest code point + 1.
//    's'    start     Start offset of tile data (anti-aliased fonts)
//    'n'    number    Number of 8-byte (16-pixel) anti-aliased tiles.
//    -'n'   name      Font name.
//    -'c'   copyright Copyright message.
//    0:               Bitmap data follows, terminated by 0xff.
bool FontBlock::verify(const uint8* data, uint32 length, const char* name) {
  // Sanity checks - is it a font file?
  // TODO: If we support big endian then this needs fixing.
  uint32 found_magic = *reinterpret_cast<const uint32*>(data) & ~1;
  bool has_checksum = *data & 1;
  if (found_magic != 0x7017f096) return false;
  if (*reinterpret_cast<const uint32*>(data + 4) != length) return false;
  if (data[length - 1] != 0xff) return false;
  uint32 offset = has_checksum ? 40 : 8;
  uint32 from = -1;
  uint32 to = -1;
  int32 start = -1;
  int32 tile_count = -1;
  while (true) {
    if (offset >= length) return false;
    int key = (signed char)data[offset];
    uint32 value = 0;
    uint32 start_of_string = 0;
    uint32 end_of_string = 0;
    if (key == 0) {
      if (offset + 1 >= length) return false;
      break;
    } else if (key > 0) {
      if (offset + 4 > length) return false;
      value = int_24(data + offset + 1);
      offset += 4;
    } else {
      if (offset + 2 > length) return false;
      start_of_string = end_of_string = offset + 1;
      while (data[end_of_string] != 0) {
        end_of_string++;
        if (end_of_string >= length) return false;
      }
      offset = end_of_string + 1;
    }
    switch (key) {
      case 'f':
        from = value;
        break;
      case 't':
        to = value;
        break;
      case 's':
        start = value;
        break;
      case 'n':
        tile_count = value;
        break;
      case -'n':
        if (name && strcmp(char_cast(data) + start_of_string, name) != 0) return false;
        break;
      default:
        break;
    }
  }
  if (from < 0 || to < 0 || from > Utils::MAX_UNICODE || from >= to) return false;
  if (start != -1 || tile_count != -1) {
    // Anti-alias mode.
    if (start > static_cast<int32>(length) ||
        tile_count > 0xffff ||  // Overflow protection.
        start + tile_count * TILE_SIZE > static_cast<int32>(length) ||
        start < 0 ||
        tile_count < 0) {
      return false;
    }
  }
  // Check integrity with Sha256 in case encrypted file has been tampered with.
  if (has_checksum) {
    uint8 non_zero_checksum = 0;
    for (int i = 0; i < Sha256::HASH_LENGTH; i++) non_zero_checksum |= data[i + 8];
    if (non_zero_checksum) {
      Sha256 sha(null);
      sha.add(data + 40, length - 40);
      uint8 calculated[Sha256::HASH_LENGTH];
      sha.get(calculated);
      // Check sha256 checksum without bailing out early.
      uint8 sha256_errors = 0;
      for (int i = 0; i < Sha256::HASH_LENGTH; i++) sha256_errors |= calculated[i] ^ data[i + 8];
      if (sha256_errors) return false;
    }
  }
  return true;
}

// A mapped font file must be verified with verify() before calling this, so there
// is no sanity checking here.
FontBlock::FontBlock(const uint8* data, bool free_on_delete)
  : data_(data),
    free_on_delete_(free_on_delete),
    tile_start_(0),
    tile_count_(0),
    font_name_(null),
    copyright_(null) {
  bool has_checksum = *data & 1;
  uint32 offset = has_checksum ? 40 : 8;
  while (int key = static_cast<signed char>(data[offset])) {
    uint32 value = 0;
    if (key <= 0x7f) {
      value = int_24(data_ + offset + 1);
    }
    switch (key) {
      case 'f':
        from_ = value;
        break;
      case 't':
        to_ = value;
        break;
      case 's':
        tile_start_ = value;
        break;
      case 'n':
        tile_count_ = value;
        break;
      case -'n':
        font_name_ = char_cast(data_) + offset;
        break;
      case -'c':
        copyright_ = char_cast(data_) + offset;
        break;
    }
    if (key > 0) {
      offset += 4;
    } else {
      while (data_[offset]) offset++;
      offset++;
    }
  }
  bitmaps_ = data_ + offset + 1;
}

FontBlock::~FontBlock() {
  if (free_on_delete_) free((void*)data_);
}

MODULE_IMPLEMENTATION(font, MODULE_FONT)

extern const uint8 FONT_PAGE_BasicLatin[1556];
extern const uint8 FONT_PAGE_ToitLogo[203];

static const FontCharacter* create_replacement(int code_point);

const Glyph Font::get_char(int cp, bool substitue_mojibake) {
  int hashed = (cp >> _CACHE_GRANULARITY_BITS) ^ (cp >> 6) ^ (cp >> 10) ^ (cp >> 14);
  hashed &= _CACHE_SIZE - 1;
  if (!_does_section_match(_cache[hashed], cp)) {
    Glyph g = _get_section_for_code_point(cp);
    if (g.pixels == null) {
      if (substitue_mojibake)
        return Glyph(create_replacement(cp), null);
      else
        return Glyph();
    }
    _cache[hashed] = g;
  }
  Glyph g = _cache[hashed];
  while (g.pixels != null) {
    if (g.pixels->code_point() == cp) return g;
    if (!_does_section_match(g, cp)) return Glyph(create_replacement(cp), null);
    g = g.next();
  }
  return Glyph(create_replacement(cp), null);
}

Glyph Font::_get_section_for_code_point(int code_point) {
  code_point &= _CACHE_MASK;
  for (int i = 0; i < _block_count; i++) {
    const FontBlock* block = _blocks[i];
    if ((block->from() & _CACHE_MASK) <= code_point && code_point < block->to()) {
      for (const FontCharacter* c = block->data(); !c->is_terminator(); c = c->next()) {
        // Check if we found the first character in the same granularity
        // section as the code point we are seeking.
        if (_does_section_match(Glyph(c, block), code_point)) return Glyph(c, block);
        // If we are not in the same granularity section and we are past the
        // one we are seeking, then we didn't find it in this block.
        if (c->code_point() > code_point) break;
      }
    }
  }
  return Glyph();
}

// Big endian tiny hex digits for missing letters in the font.
static const uint8 REPLACEMENT_BITMAP[] = {
// ▄▀▀▄
// █  █
//  ▀▀
  0x69, 0x99, 0x60,

//  █
//  █
//  ▀
  0x44, 0x44, 0x40,

// ▄▀▀▄
//  ▄█▀
// ▀▀▀▀
  0x69, 0x36, 0xf0,

// ▄▀▀▄
// ▄ ▀█
//  ▀▀
  0x69, 0x39, 0x60,

//  ▄█
// █▄█▄
//   ▀
  0x26, 0xaf, 0x20,

// █▀▀▀
// ▀▀▀▄
// ▀▀▀
  0xf8, 0xe1, 0xe0,

//  ▄▀▀
// █▀▀▄
//  ▀▀
  0x34, 0xe9, 0x60,

// ▀▀▀█
//  ▄▀
// ▀
  0xf1, 0x24, 0x80,

// ▄▀▀▄
// ▄▀▀▄
//  ▀▀
  0x69, 0x69, 0x60,

// ▄▀▀▄
//  ▀█▀
// ▀▀
  0x69, 0x72, 0xc0,

// ▄▀▀▄
// █▀▀█
// ▀  ▀
  0x69, 0xf9, 0x90,

// █▀▀▄
// █▀▀▄
// ▀▀▀
  0xe9, 0xe9, 0xe0,

// ▄▀▀▄
// █  ▄
//  ▀▀
  0x69, 0x89, 0x60,

// █▀▀▄
// █  █
// ▀▀▀
  0xe9, 0x99, 0xe0,

// █▀▀▀
// █▀▀▀
// ▀▀▀▀
  0xf8, 0xe8, 0xf0,

// █▀▀▀
// █▀▀▀
// ▀
  0xf8, 0xe8, 0x80,
};

static const int REPLACEMENT_CHAR_WIDTH = 14;
static const int REPLACEMENT_CHAR_HEIGHT = 11;
static const int REPLACEMENT_DATA_SIZE = 2 * REPLACEMENT_CHAR_HEIGHT;
// Encoded, it grows 25%.
static const int REPLACEMENT_ENCODED_SIZE = (int)(REPLACEMENT_DATA_SIZE * 1.25 + 0.99);
static const int REPLACEMENT_CODE_POINT_OFFSET = 5;
static const int BITMAP_OFFSET = 9;
static uint8 replacement[] = {
  REPLACEMENT_CHAR_WIDTH + 2,    // Pixel width.
  REPLACEMENT_CHAR_WIDTH,        // Bounding box.
  REPLACEMENT_CHAR_HEIGHT, 0, 0, // Bounding box
  0, 0, 0,      // Code point will be patched in here, in 3-byte form.
  REPLACEMENT_ENCODED_SIZE,      // Size of the replacement data.
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // We will emit 10 bits per byte of bitmap
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // data so this is plenty of space.
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

static void replacement_nibble(uint8* start, int bits, int x) {
  while (x >= 8) {
    x -= 8;
    start++;
  }
  int mask = 8;
  for (int i = 0; i < 4; i++) {
    if (bits & mask) *start |= 0x80 >> x;
    x++;
    if (x & 8) start++;
    x &= 7;
    mask >>= 1;
  }
}

static void replacement_render(uint8* start, int digit, int x) {
  const uint8* data = REPLACEMENT_BITMAP + (digit & 0xf) * 3;
  for (unsigned i = 0; i < 5; i++) {
    replacement_nibble(start + (i << 1), data[i >> 1] >> (((i & 1) ^ 1) << 2), x);
  }
}

static void set_replacement(int code_point) {
  replacement[REPLACEMENT_CODE_POINT_OFFSET] = (code_point >> 16) | 0xc0;
  replacement[REPLACEMENT_CODE_POINT_OFFSET + 1] = code_point >> 8;
  replacement[REPLACEMENT_CODE_POINT_OFFSET + 2] = code_point >> 0;
  uint8 bitmap[REPLACEMENT_DATA_SIZE];
  memset(bitmap, 0, sizeof(bitmap));

  // Render the tiny hex digits on a 2x2 or 3x2 grid.
  if (code_point <= 0xffff) {
    replacement_render(bitmap, code_point >> 12, 3);
    replacement_render(bitmap, code_point >> 8, 8);
    replacement_render(bitmap + 12, code_point >> 4, 3);
    replacement_render(bitmap + 12, code_point >> 0, 8);
  } else {
    replacement_render(bitmap, code_point >> 20, 0);
    replacement_render(bitmap, code_point >> 16, 5);
    replacement_render(bitmap, code_point >> 12, 10);
    replacement_render(bitmap + 12, code_point >> 8, 0);
    replacement_render(bitmap + 12, code_point >> 4, 5);
    replacement_render(bitmap + 12, code_point >> 0, 10);
  }
  uint8* compressed_image_data = replacement + BITMAP_OFFSET;
  uint8 accumulator = 0;
  int bits_output = 0;

  // Emit the bitmap into the replacement buffer as a series of 2-bit NEW
  // commands and 8-bit bitmap data.
  for (int i = 0; i < REPLACEMENT_DATA_SIZE; i++) {
    accumulator |= FontDecompresser::NEW << (6 - bits_output);
    bits_output += 2;
    int bitmap_data = bitmap[i];
    if (bits_output == 8) {
      // Flush the full accumulator to memory.
      *compressed_image_data++ = accumulator;
      accumulator = 0;
      bits_output = 0;
      // We are at a byte boundary so we can emit the bitmap byte directly.
      *compressed_image_data++ = bitmap_data;
    } else {
      // Fill up the partially full accumulator with part of the bitmap byte.
      accumulator |= bitmap_data >> bits_output;
      *compressed_image_data++ = accumulator;
      // Put the rest of the bitmap byte in the accumulator.
      accumulator = bitmap_data << (8 - bits_output);
    }
  }
  if (bits_output != 0) *compressed_image_data++ = accumulator;
  ASSERT(compressed_image_data = replacement + BITMAP_OFFSET + REPLACEMENT_ENCODED_SIZE);
}

static const FontCharacter* create_replacement(int code_point) {
  set_replacement(code_point);
  return reinterpret_cast<FontCharacter*>(replacement);
}

void FontDecompresser::compute_next_line() {
  int bytes = (_width + 7) >> 3;
  for (int i = 0; i < bytes; i++) {
    int next = line_[i];
    if (_saved_sames != 0) {
      _saved_sames--;
      continue;
    }
    switch (_command(_control_position++)) {
      case SAME_1:
        break;
      case PREFIX_2:
        switch (_command(_control_position++)) {
          case SAME_4_7:
            _saved_sames = 3 + (_command(_control_position++));
            break;
          case GROW_RIGHT:
            next |= next >> 1;
            break;
          case RIGHT:
            next >>= 1;
            break;
          case PREFIX_2_3: 
            switch (_command(_control_position++)) {
              case SAME_10_25: {
                int hi = _command(_control_position++);
                int lo = _command(_control_position++);
                _saved_sames = 9 + (hi << 2) + lo;
                break;
              }
              case LO_BIT:
                next = 1;
                break;
              case HI_BIT:
                next = 0x80;
                break;
              case GROW:
                next |= (next << 1) | (next >> 1);
                break;
            }
            break;
        }
        break;
      case PREFIX_3:
        switch (_command(_control_position++)) {
          case LEFT:
            next <<= 1;
            break;
          case GROW_LEFT:
            next |= next << 1;
            break;
          case ZERO:
            next = 0;
            break;
          case PREFIX_3_3:
            switch (_command(_control_position++)) {
              case SHRINK_LEFT:
                next &= next >> 1;
                break;
              case SHRINK_RIGHT:
                next &= next << 1;
                break;
              case SHRINK:
                next = (next << 1) & (next >> 1);
                break;
              case ONES:
                next = 0xff;
                break;
            }
            break;
        }
        break;
      case NEW: {
        next = _command(_control_position++) << 6;
        next |= _command(_control_position++) << 4;
        next |= _command(_control_position++) << 2;
        next |= _command(_control_position++);
        break;
      }
    }
    line_[i] = next;
  }
}

PRIMITIVE(get_font) {
#if !defined(CONFIG_TOIT_BIT_DISPLAY) && !defined(CONFIG_TOIT_BYTE_DISPLAY)
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(SimpleResourceGroup, resource_group, StringOrSlice, string);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;
  Font* font = _new Font(resource_group);
  if (!font) MALLOC_FAILED;
  SimpleResourceAllocationManager<Font> font_allocation_manager(font);
  const uint8* page1 = null;
  size_t page1_length = 0;
  if (string.slow_equals("sans10")) {
    page1 = FONT_PAGE_BasicLatin;
    page1_length = sizeof(FONT_PAGE_BasicLatin);
  } else if (string.slow_equals("logo")) {
    page1 = FONT_PAGE_ToitLogo;
    page1_length = sizeof(FONT_PAGE_ToitLogo);
  }
  if (page1 == null) return process->program()->null_object();
  if (!FontBlock::verify(page1, page1_length, null)) INVALID_ARGUMENT;
  FontBlock* block1 = _new FontBlock(page1, false);
  if (!block1) ALLOCATION_FAILED;
  if (!font->add(block1)) {
    delete block1;
    ALLOCATION_FAILED;
  }
  proxy->set_external_address(font_allocation_manager.keep_result());
  return proxy;
#endif  // !defined(CONFIG_TOIT_BIT_DISPLAY) && !defined(CONFIG_TOIT_BYTE_DISPLAY)
}

PRIMITIVE(get_nonbuiltin) {
  ARGS(SimpleResourceGroup, group, Array, arrays);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  Font* font = _new Font(group);
  if (!font) ALLOCATION_FAILED;

  SimpleResourceAllocationManager<Font> font_manager(font);

  for (int index = 0; index < arrays->length(); index++) {
    Object* block_array = arrays->at(index);
    const uint8* bytes;
    int length;
    if (!block_array->is_heap_object()) WRONG_TYPE;
    if (!block_array->byte_content(process->program(), &bytes, &length, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
    // TODO: We should perhaps avoid redoing this verification if the data is
    // in flash and we already did it once.
    if (!FontBlock::verify(bytes, length, null)) {
      INVALID_ARGUMENT;
    }
    AllocationManager manager(process);
    const uint8* font_characters;
    bool was_allocated = false;
    // If the byte array is in the program image we should just point at it.
    if (Heap::in_read_only_program_heap(HeapObject::cast(block_array), process->object_heap())) {
      font_characters = bytes;
    } else {
      auto mutable_font_characters = manager.alloc(length);
      was_allocated = true;
      if (!mutable_font_characters) ALLOCATION_FAILED;
      memcpy(mutable_font_characters, bytes, length);
      font_characters = mutable_font_characters;
    }
    FontBlock* block = _new FontBlock(font_characters, was_allocated);
    if (!block) MALLOC_FAILED;
    if (!font->add(block)) MALLOC_FAILED;
    // TODO(kasper): This looks fishy. What happens if processing the next
    // entry fails? Do we just leak the memory allocated up to that point?
    manager.keep_result();
  }

  proxy->set_external_address(font_manager.keep_result());

  return proxy;
}

PRIMITIVE(contains) {
  ARGS(Font, font, int, code_point);
  if (code_point < 0 || code_point > Utils::MAX_UNICODE) OUT_OF_RANGE;
  const bool mojibake = false;
  const Glyph glyph = font->get_char(code_point, mojibake);
  return BOOL(glyph.pixels != null);
}

PRIMITIVE(delete_font) {
  ARGS(Font, font);
  font->resource_group()->unregister_resource(font);

  font_proxy->clear_external_address();
  return process->program()->null_object();
}

void iterate_font_characters(Blob bytes, Font* font, const std::function<void (const Glyph)>& f) {
  for (int i = 0; i < bytes.length(); i++) {
    int c = bytes.address()[i];
    if (c >= 0x80) {
      int prefix = c;
      int nbytes = Utils::bytes_in_utf_8_sequence(prefix);
      c = Utils::payload_from_prefix(prefix);
      for (int j = 1; j < nbytes; j++) {
        int b = bytes.address()[i + j];
        c <<= 6;
        c |= b & 0x3f;
      }
      i += nbytes - 1;
    }
    const Glyph glyph = font->get_char(c);
    if (glyph.pixels != null) {
      f(glyph);
    }
  }
}

struct CaptureBundle {
  int top;
  int left;
  int bottom;
  int right;
};

PRIMITIVE(get_text_size) {
  ARGS(StringOrSlice, bytes, Font, font, Array, result);
  int pixels = 0;
  const int A_LARGE_NUMBER = 1000000;
  CaptureBundle box = {
    .top = -A_LARGE_NUMBER,
    .left = A_LARGE_NUMBER,
    .bottom = A_LARGE_NUMBER,
    .right = -A_LARGE_NUMBER
  };
  iterate_font_characters(bytes, font, [&](Glyph g) {
    const FontCharacter* c = g.pixels;
    if (pixels + c->box_xoffset_ < box.left) box.left = pixels + c->box_xoffset_;
    if (c->box_yoffset_ < box.bottom) box.bottom = c->box_yoffset_;
    int r = pixels + c->box_xoffset_ + c->box_width_;
    if (r > box.right) box.right = r;
    int t = c->box_yoffset_ + c->box_height_;
    if (t > box.top) box.top = t;
    pixels += c->pixel_width;
  });

  if (result->length() >= 4) {
    if (box.left > box.right) box.left = box.right = box.top = box.bottom = 0;
    result->at_put(0, Smi::from(box.right - box.left));
    result->at_put(1, Smi::from(box.top - box.bottom));
    result->at_put(2, Smi::from(box.left));
    result->at_put(3, Smi::from(box.bottom));
  }

  return Smi::from(pixels);
}


// Copyright: "Copyright (c) 1984, 1987 Adobe Systems Incorporated. All Rights Reserved. Copyright (c) 1988, 1991 Digital Equipment Corporation. All Rights Reserved."

// ISO10646-1 extension by Markus Kuhn <mkuhn@acm.org>, 2001-03-20
//
// +
//  Copyright 1984-1989, 1994 Adobe Systems Incorporated.
//  Copyright 1988, 1994 Digital Equipment Corporation.
//
//  Adobe is a trademark of Adobe Systems Incorporated which may be
//  registered in certain jurisdictions.
//  Permission to use these trademarks is hereby granted only in
//  association with the images described in this file.
//
//  Permission to use, copy, modify, distribute and sell this software
//  and its documentation for any purpose and without fee is hereby
//  granted, provided that the above copyright notices appear in all
//  copies and that both those copyright notices and this permission
//  notice appear in supporting documentation, and that the names of
//  Adobe Systems and Digital Equipment Corporation not be used in
//  advertising or publicity pertaining to distribution of the software
//  without specific, written prior permission.  Adobe Systems and
//  Digital Equipment Corporation make no representations about the
//  suitability of this software for any purpose.  It is provided "as
//  is" without express or implied warranty.
// -

/// Bitmaps for the sans_10 font

// Autogenerated by convertfont.toit from the BDF file font-adobe-100dpi-1.0.3/helvR10.bdf

/// sans_10 characters 0 to 7f, 1556 bytes
extern const uint8 FONT_PAGE_BasicLatin[1556] = {
  0x96, 0xf0, 0x17, 0x70, // Magic number 0x7017f096.
  0x14, 0x6, 0x0, 0x0, // Length 1556.
  0x92, 's','a','n','s','_','1','0',0, // Font name "sans_10".
  0x9d, '"','C','o','p','y','r','i','g','h','t',' ','(','c',')',' ',
  '1','9','8','4',',',' ','1','9','8','7',' ','A','d','o','b','e',' ',
  'S','y','s','t','e','m','s',' ','I','n','c','o','r','p','o','r','a','t','e','d','.',' ',
  'A','l','l',' ','R','i','g','h','t','s',' ','R','e','s','e','r','v','e','d','.',' ',
  'C','o','p','y','r','i','g','h','t',' ','(','c',')',' ','1','9','8','8',',',' ',
  '1','9','9','1',' ','D','i','g','i','t','a','l',' ','E','q','u','i','p','m','e','n','t',' ',
  'C','o','r','p','o','r','a','t','i','o','n','.',' ','A','l','l',' ',
  'R','i','g','h','t','s',' ','R','e','s','e','r','v','e','d','.','"',0, // Copyright message
  102, 0x0, 0x0, 0x0, // Unicode range start 0x000000.
  116, 0x7f, 0x0, 0x0, // Unicode range end 0x00007f.
  0,
  4, 1, 0, 0, 0, // 0020 space
  32, 0,
  4, 1, 11, 2, 0, // 0021 exclam
  33, 3, 0xba, 0x3e, 0xb9,
  5, 3, 3, 1, 8, // 0022 quotedbl
  34, 2, 0x28, 0x14,
  8, 7, 10, 0, 0, // 0023 numbersign
  35, 8, 0x5, 0x14, 0x7e, 0xa, 0x13, 0xf0, 0x50, 0x50,
  8, 7, 14, 0, 254, // 0024 dollar
  36, 15, 0x4, 0x7, 0xc2, 0x49, 0x24, 0x5, 0x0, 0xe0, 0x14, 0x4, 0x89, 0x24, 0x7c, 0x4, 0x10,
  12, 11, 11, 0, 0, // 0025 percent
  37, 16, 0x1c, 0x2e, 0x22, 0x79, 0x47, 0x24, 0x2, 0x71, 0xc4, 0x9, 0x30, 0x30, 0x20, 0x50, 0x84, 0xc0,
  10, 8, 10, 1, 0, // 0026 ampersand
  38, 11, 0xc, 0x4, 0x84, 0x30, 0xf4, 0x52, 0x22, 0x88, 0x42, 0x28, 0x71,
  3, 1, 3, 1, 8, // 0027 quotesingle
  39, 2, 0xb9, 0x40,
  5, 3, 14, 1, 253, // 0028 parenleft
  40, 5, 0x8, 0x31, 0xc8, 0xe9, 0xa0,
  5, 3, 14, 1, 253, // 0029 parenright
  41, 4, 0xba, 0x9a, 0x8f, 0x1c,
  7, 5, 5, 1, 6, // 002a asterisk
  42, 7, 0x8, 0xa, 0x81, 0xc0, 0xa8, 0x8, 0x0,
  9, 7, 7, 1, 1, // 002b plus
  43, 5, 0x4, 0x14, 0xfe, 0x4, 0x14,
  3, 2, 4, 0, 254, // 002c comma
  44, 3, 0x10, 0x17, 0x0,
  4, 3, 1, 0, 4, // 002d hyphen
  45, 2, 0x38, 0x0,
  3, 1, 2, 1, 0, // 002e period
  46, 1, 0xb9,
  4, 4, 11, 0, 0, // 002f slash
  47, 5, 0x4, 0x1c, 0x5c, 0x5c, 0x50,
  8, 6, 11, 1, 0, // 0030 zero
  48, 5, 0x1e, 0x8, 0x48, 0xd1, 0xe0,
  8, 3, 11, 2, 0, // 0031 one
  49, 5, 0x8, 0xe, 0x0, 0x82, 0x34,
  8, 6, 11, 1, 0, // 0032 two
  50, 8, 0x1e, 0x8, 0x44, 0x4, 0xcc, 0xcc, 0xc4, 0xfc,
  8, 6, 11, 1, 0, // 0033 three
  51, 10, 0x1e, 0x8, 0x44, 0x4, 0x43, 0x80, 0x11, 0x21, 0x11, 0xe0,
  8, 7, 11, 1, 0, // 0034 four
  52, 10, 0x1, 0x34, 0x14, 0x9, 0x4, 0x42, 0x11, 0x3f, 0x80, 0x45,
  8, 6, 11, 1, 0, // 0035 five
  53, 9, 0x3f, 0x2e, 0x53, 0xe0, 0x4, 0x52, 0x11, 0x1e, 0x0,
  8, 6, 11, 1, 0, // 0036 six
  54, 10, 0x1e, 0x8, 0x4b, 0x92, 0xe0, 0xc4, 0x21, 0x15, 0x1e, 0x0,
  8, 6, 11, 1, 0, // 0037 seven
  55, 6, 0x3f, 0x0, 0x4c, 0x71, 0xc7, 0x14,
  8, 6, 11, 1, 0, // 0038 eight
  56, 8, 0x1e, 0x8, 0x45, 0x47, 0x82, 0x11, 0x51, 0xe0,
  8, 6, 11, 1, 0, // 0039 nine
  57, 9, 0x1e, 0x8, 0x45, 0x47, 0xc0, 0x11, 0x21, 0x11, 0xe0,
  3, 1, 8, 1, 0, // 003a colon
  58, 4, 0xb9, 0xe5, 0x6e, 0x40,
  4, 2, 10, 0, 254, // 003b semicolon
  59, 5, 0x10, 0x1e, 0x54, 0x40, 0x5c,
  8, 6, 5, 1, 2, // 003c less
  60, 7, 0x3, 0x3, 0x3, 0x0, 0x30, 0x3, 0x0,
  9, 6, 3, 1, 3, // 003d equal
  61, 3, 0x3f, 0x38, 0xfc,
  8, 6, 5, 1, 2, // 003e greater
  62, 7, 0x30, 0x3, 0x0, 0x30, 0x30, 0x30, 0x0,
  8, 6, 11, 1, 0, // 003f question
  63, 9, 0xc, 0xc, 0xc2, 0x11, 0x1, 0x33, 0x33, 0x82, 0x4,
  13, 11, 12, 1, 255, // 0040 at
  64, 22, 0x3, 0xd0, 0xc0, 0xc0, 0x10, 0x2, 0x1, 0x18, 0xa0, 0x22, 0x42, 0x2, 0x45, 0x52, 0x4f, 0x8, 0xdc, 0x10, 0x3a, 0x6e, 0x7, 0xf8,
  9, 9, 11, 0, 0, // 0041 A
  65, 13, 0x2, 0x1b, 0xd0, 0x51, 0x50, 0x89, 0x51, 0x5, 0x1f, 0xd1, 0x5, 0xba, 0xe5,
  9, 7, 11, 1, 0, // 0042 B
  66, 11, 0x3f, 0x8, 0x62, 0x9, 0x21, 0xf, 0x82, 0x10, 0x82, 0x74, 0xfc,
  10, 8, 11, 1, 0, // 0043 C
  67, 9, 0x7, 0x6, 0x31, 0x6, 0xe8, 0x4, 0x11, 0x8c, 0x1c,
  10, 8, 11, 1, 0, // 0044 D
  68, 9, 0x3e, 0x8, 0x62, 0x8, 0x81, 0x80, 0x82, 0xd3, 0xe0,
  9, 7, 11, 1, 0, // 0045 E
  69, 7, 0x3f, 0xae, 0x54, 0xfc, 0xb9, 0x53, 0xf8,
  8, 7, 11, 1, 0, // 0046 F
  70, 6, 0x3f, 0xae, 0x54, 0xfc, 0xba, 0x0,
  11, 9, 11, 1, 0, // 0047 G
  71, 14, 0x7, 0x91, 0x86, 0xef, 0x5c, 0xe5, 0x21, 0xee, 0xb9, 0x5a, 0x46, 0x34, 0x1c, 0x40,
  10, 8, 11, 1, 0, // 0048 H
  72, 5, 0x20, 0x60, 0xfc, 0x81, 0x80,
  4, 1, 11, 2, 0, // 0049 I
  73, 2, 0xba, 0xc0,
  7, 6, 11, 0, 0, // 004a J
  74, 5, 0x1, 0x23, 0x21, 0x11, 0xe0,
  9, 8, 11, 1, 0, // 004b K
  75, 13, 0x20, 0x88, 0x42, 0x20, 0x90, 0x28, 0x34, 0x90, 0x22, 0x8, 0x42, 0x8, 0x81,
  8, 6, 11, 2, 0, // 004c L
  76, 4, 0xba, 0x35, 0x3f, 0x0,
  12, 11, 11, 0, 0, // 004d M
  77, 14, 0xb8, 0x20, 0x9d, 0x52, 0x80, 0xa0, 0x52, 0x44, 0x20, 0x52, 0x29, 0x52, 0x11, 0x50,
  10, 8, 11, 1, 0, // 004e N
  78, 9, 0x30, 0x4a, 0x14, 0x91, 0x48, 0x94, 0x85, 0x48, 0x34,
  11, 9, 11, 1, 0, // 004f O
  79, 12, 0x7, 0x11, 0x8d, 0x10, 0x5b, 0xae, 0x8d, 0x10, 0x78, 0x63, 0x41, 0xc4,
  9, 7, 11, 1, 0, // 0050 P
  80, 8, 0x3f, 0x8, 0x62, 0x9, 0xd3, 0xf2, 0xe8, 0x0,
  11, 9, 11, 1, 0, // 0051 Q
  81, 15, 0x7, 0x11, 0x8d, 0x10, 0x5b, 0xae, 0x80, 0x88, 0x48, 0x44, 0x43, 0xe9, 0x41, 0xcb, 0x80,
  10, 8, 11, 1, 0, // 0052 R
  82, 10, 0x3f, 0x88, 0x32, 0x5, 0x20, 0x8f, 0xc2, 0x8, 0x81, 0x54,
  9, 7, 11, 1, 0, // 0053 S
  83, 13, 0xe, 0xc, 0x62, 0xa, 0xe1, 0x80, 0x18, 0x1, 0xbc, 0x20, 0x8c, 0x60, 0xe0,
  9, 9, 11, 0, 0, // 0054 T
  84, 5, 0xfe, 0xe0, 0x23, 0xac, 0x80,
  10, 8, 11, 1, 0, // 0055 U
  85, 5, 0x20, 0x63, 0x44, 0x20, 0xf0,
  9, 9, 11, 0, 0, // 0056 V
  86, 12, 0xba, 0xe5, 0x10, 0x79, 0x46, 0x34, 0x22, 0x54, 0x14, 0x57, 0xe5, 0x40,
  13, 13, 11, 0, 0, // 0057 W
  87, 12, 0x20, 0x80, 0x85, 0x21, 0x51, 0x17, 0x20, 0xa, 0xa, 0x8, 0x3e, 0xc5,
  9, 9, 11, 0, 0, // 0058 X
  88, 15, 0xba, 0xe1, 0x7, 0x82, 0x24, 0x14, 0x7e, 0x54, 0x14, 0x42, 0x24, 0x41, 0x56, 0xeb, 0x80,
  9, 9, 11, 0, 0, // 0059 Y
  89, 12, 0xba, 0xe3, 0x5, 0x10, 0x78, 0x22, 0x54, 0x14, 0x41, 0xc7, 0xe8, 0xc0,
  9, 7, 11, 1, 0, // 005a Z
  90, 9, 0x3f, 0x80, 0x2c, 0xcd, 0xf7, 0x37, 0xdc, 0x3f, 0x80,
  4, 3, 14, 1, 253, // 005b bracketleft
  91, 5, 0x38, 0x2e, 0xb0, 0x4e, 0x0,
  4, 4, 11, 0, 0, // 005c backslash
  92, 4, 0xb9, 0xa5, 0xa5, 0xa5,
  4, 3, 14, 0, 253, // 005d bracketright
  93, 5, 0x38, 0x2, 0xb, 0x4, 0xe0,
  7, 5, 5, 1, 6, // 005e asciicircum
  94, 5, 0x8, 0x5, 0x4, 0x88, 0x40,
  8, 8, 1, 0, 253, // 005f underscore
  95, 1, 0xfc,
  5, 2, 2, 1, 9, // 0060 grave
  96, 2, 0xba, 0x80,
  8, 7, 8, 1, 0, // 0061 a
  97, 10, 0x1e, 0xc, 0xc0, 0x10, 0x7c, 0x31, 0x8, 0x43, 0x30, 0x76,
  7, 6, 11, 1, 0, // 0062 b
  98, 9, 0xb9, 0x4b, 0x83, 0x30, 0x84, 0x54, 0xcc, 0x2e, 0x0,
  7, 6, 8, 1, 0, // 0063 c
  99, 8, 0x1e, 0xc, 0xcb, 0x94, 0x84, 0x33, 0x7, 0x80,
  8, 6, 11, 1, 0, // 0064 d
  100, 9, 0x1, 0x14, 0x74, 0x33, 0x8, 0x45, 0x4c, 0xc1, 0xd0,
  8, 6, 8, 1, 0, // 0065 e
  101, 9, 0x1e, 0xc, 0xc2, 0x10, 0xfc, 0xb9, 0x33, 0x7, 0x80,
  4, 4, 11, 0, 0, // 0066 f
  102, 5, 0xc, 0x4, 0x6, 0xff, 0xa2,
  8, 6, 11, 1, 253, // 0067 g
  103, 11, 0x1d, 0xc, 0xc2, 0x11, 0x53, 0x30, 0x74, 0x1, 0xc, 0xc1, 0xe0,
  8, 6, 11, 1, 0, // 0068 h
  104, 6, 0xb9, 0x4b, 0x83, 0x30, 0x84, 0x84,
  3, 1, 11, 1, 0, // 0069 i
  105, 3, 0xb9, 0xeb, 0xa3,
  3, 3, 14, 255, 253, // 006a j
  106, 6, 0x8, 0x1e, 0x8, 0x23, 0x53, 0x0,
  7, 6, 11, 1, 0, // 006b k
  107, 12, 0xb9, 0x48, 0x82, 0x40, 0xa0, 0x30, 0xa, 0x2, 0x40, 0x88, 0x21, 0x0,
  3, 1, 11, 1, 0, // 006c l
  108, 2, 0xba, 0xc0,
  11, 9, 8, 1, 0, // 006d m
  109, 6, 0x2c, 0xd3, 0x32, 0xef, 0x6c, 0x10,
  8, 6, 8, 1, 0, // 006e n
  110, 5, 0x2e, 0xc, 0xc2, 0x12, 0x10,
  8, 6, 8, 1, 0, // 006f o
  111, 7, 0x1e, 0xc, 0xc2, 0x11, 0x53, 0x30, 0x78,
  8, 6, 11, 1, 253, // 0070 p
  112, 9, 0x2e, 0xc, 0xc2, 0x11, 0x53, 0x30, 0xb8, 0xb9, 0x40,
  8, 6, 11, 1, 253, // 0071 q
  113, 9, 0x1d, 0xc, 0xc2, 0x11, 0x53, 0x30, 0x74, 0x1, 0x14,
  5, 4, 8, 1, 0, // 0072 r
  114, 4, 0x2c, 0xc, 0xc, 0x84,
  7, 5, 8, 1, 0, // 0073 s
  115, 10, 0x1c, 0x8, 0x83, 0x0, 0x70, 0x6, 0x3c, 0x22, 0x7, 0x0,
  4, 4, 10, 0, 0, // 0074 t
  116, 5, 0x10, 0x1b, 0xfe, 0x84, 0x30,
  7, 6, 8, 1, 0, // 0075 u
  117, 5, 0x21, 0x21, 0x33, 0x7, 0x40,
  7, 7, 8, 0, 0, // 0076 v
  118, 6, 0x20, 0x91, 0x11, 0x42, 0x87, 0xe0,
  10, 9, 8, 0, 0, // 0077 w
  119, 9, 0x22, 0x2e, 0x80, 0x49, 0xe5, 0x15, 0x50, 0x89, 0x50,
  7, 7, 8, 0, 0, // 0078 x
  120, 9, 0x31, 0x84, 0x40, 0xa3, 0xe4, 0x28, 0x11, 0xc, 0x60,
  7, 7, 11, 0, 253, // 0079 y
  121, 10, 0x20, 0x8c, 0x21, 0x11, 0x9, 0x2, 0x80, 0x63, 0xd7, 0x70,
  7, 6, 8, 0, 0, // 007a z
  122, 7, 0x3f, 0x0, 0x4c, 0xcc, 0xcc, 0x3f, 0x0,
  5, 5, 14, 0, 253, // 007b braceleft
  123, 8, 0x6, 0x2, 0x5, 0x73, 0x2a, 0xa0, 0x6, 0x0,
  3, 1, 14, 1, 253, // 007c bar
  124, 2, 0xba, 0xc3,
  5, 5, 14, 0, 253, // 007d braceright
  125, 8, 0x30, 0x2, 0x5, 0x6a, 0xb3, 0x20, 0x30, 0x0,
  8, 6, 3, 1, 3, // 007e asciitilde
  126, 4, 0x19, 0xb, 0x42, 0x60,
  0xff};

const unsigned char FONT_PAGE_ToitLogo[203] = {
  0x96, 0xf0, 0x17, 0x70, // Magic number 0x7017f096.
  0xcb, 0x0, 0x0, 0x0, // Length 203.
  0x92, 'l','o','g','o',0, // Font name "logo".
  0x9d, 'C','o','p','y','r','i','g','h','t',' ','(','C',')',' ',
  '2','0','2','0',' ','T','o','i','t','w','a','r','e',' ','A','p','S','.',' ',
  'A','l','l',' ','r','i','g','h','t','s',' ','r','e','s','e','r','v','e','d','.',0, // Copyright message
  102, 0x0, 0x0, 0x0, // Unicode range start 0x000000.
  116, 0x7f, 0x0, 0x0, // Unicode range end 0x00007f.
  0,
  65, 64, 40, 0, 0, // 0041 U+0041
  65, 117, 0x1c, 0x22, 0xe, 0x3f, 0x84, 0x3, 0x3f, 0x13, 0xe2, 0x1, 0xfd, 0x7, 0xff, 0x54, 0x3, 0xd3, 0x82, 0xd4, 0xf8, 0x51, 0xff, 0x3b, 0x80, 0xff, 0xcc, 0x0, 0x3f, 0x4c, 0x5, 0xb5, 0x3f, 0x3f, 0xce, 0x5e, 0x3, 0xff, 0x4c, 0x8, 0x39, 0x3f, 0x3a, 0x10, 0x7c, 0xe0, 0x8a, 0xb2, 0x2a, 0xcb, 0x3e, 0xcf, 0xb2, 0xb6, 0x62, 0xd9, 0xb1, 0x3, 0xc9, 0x54, 0x40, 0x5f, 0x7c, 0x50, 0x22, 0xf5, 0xd9, 0x5b, 0xe5, 0x72, 0x97, 0x69, 0x73, 0xc5, 0xca, 0x6d, 0x65, 0x72, 0x9d, 0xca, 0x6d, 0xca, 0x87, 0x72, 0x9d, 0xca, 0xb9, 0xc6, 0xe7, 0xa9, 0xd6, 0xa7, 0x56, 0x77, 0xaa, 0x71, 0xa9, 0xc7, 0xa7, 0x1e, 0x9c, 0x51, 0xf3, 0x56, 0x4f, 0x85, 0xf, 0xf1, 0x47, 0xfc, 0x5a, 0xc5, 0xac, 0x50, 0x1c, 0xc0, 0x50, 0x3e, 0xe4,
  0xff};

}
