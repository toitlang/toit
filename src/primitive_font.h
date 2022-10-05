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

#pragma once

#include <functional>

#include "process.h"
#include "objects.h"
#include "objects_inline.h"
#include "primitive.h"

namespace toit {

class PixelBox {
 public:
  virtual int box_width() const = 0;
  virtual int box_height() const = 0;
  virtual int box_xoffset() const = 0;
  virtual int box_yoffset() const = 0;
};

// The raw data for one character in a particular font.
// This is generated from a BDF font file by a script.
class FontCharacter {
 public:
  static const int FIELD_COUNT = 6;
  uint8 pixel_width;
  uint8 box_width_;
  uint8 box_height_;
  signed char box_xoffset_;
  signed char box_yoffset_;
  // Code points and sizes near 0 are more common, so it's coded as following
  // without causing high code points and sizes to take more than the 3 bytes
  // they would have to take in a simple layout.
  // 0x000000-0x00007f: 0xxx xxxx
  // 0x000080-0x003fff: 10xx xxxx xxxx xxxx
  // 0x004000-0x1fffff: 110x xxxx xxxx xxxx xxxx xxxx
  // End of font block: 1111 1111
  // This covers up to max Unicode 0x10ffff.
  //
  // Variable length 1-3 byte code-point field, followed by variable
  // length 1-3 byte bitmap length field.
  uint8 code_point_field_;

  int decode_cardinal(const uint8* encoding) const {
    uint8 byte_0 = encoding[0];
    ASSERT(byte_0 < 0xff);
    if (byte_0 < 0x80) return byte_0;
    if (byte_0 < 0xc0) return ((byte_0 & 0x3f) << 8) | encoding[1];
    return ((encoding[0] & 0x1f) << 16) | (encoding[1] << 8) | encoding[2];
  }

  int cardinal_size(const uint8* encoding) const {
    uint8 byte_0 = encoding[0];
    ASSERT(byte_0 < 0xff);
    if (byte_0 < 0x80) return 1;
    if (byte_0 < 0xc0) return 2;
    return 3;
  }

  int code_point() const {
    return decode_cardinal(&code_point_field_);
  }

  const uint8* bitmap() const {
    // Skip two variable length encoded integers.
    int code_point_bytes = cardinal_size(&code_point_field_);
    const uint8* length_field = &code_point_field_ + code_point_bytes;
    int length_field_bytes = cardinal_size(length_field);
    return length_field + length_field_bytes;
  }

  bool is_terminator() const { return code_point_field_ == 0xff; }

  const FontCharacter* next() const {
    // Skip two variable length encoded integers.
    int code_point_bytes = cardinal_size(&code_point_field_);
    const uint8* length_field = &code_point_field_ + code_point_bytes;
    int length_field_bytes = cardinal_size(length_field);
    int bitmap_length = decode_cardinal(length_field);
    const FontCharacter* n = reinterpret_cast<const FontCharacter*>(length_field + length_field_bytes + bitmap_length);
    if (n->is_terminator()) return null;
    return n;
  }
};

class FontCharacterPixelBox : public PixelBox {
 public:
  virtual int box_width() const { return font_character_->box_width_; }
  virtual int box_height() const { return font_character_->box_height_; }
  virtual int box_xoffset() const { return font_character_->box_xoffset_; }
  virtual int box_yoffset() const { return font_character_->box_yoffset_; }
  FontCharacterPixelBox(const FontCharacter* font_character) : font_character_(font_character) {}

 private:
  const FontCharacter* font_character_;
};

// A block of Unicode (eg ASCII, Armenian, Deseret) in a particular font.
class FontBlock {
 public:
  // A mapped font file must be verified with verify() before calling this.
  FontBlock(const uint8* data, bool free_on_delete);
  ~FontBlock();

  // Checks a file to see if memory mapped file data is a valid Toit font file
  // with a given font name.  Pass null as font name to skip that part of the
  // verification.
  static bool verify(const uint8* data, uint32 length, const char* name);
  int from() const { return from_; }
  int to() const { return to_ ; }
  const char* font_name() const { return font_name_; }
  const char* copyright() const { return copyright_; }
  const FontCharacter* data() const { return reinterpret_cast<const FontCharacter*>(bitmaps_); }

 private:
  static uint32 int_24(const uint8* p) {
    return
      static_cast<uint32>(p[0]) +
      (static_cast<uint32>(p[1]) << 8) +
      (static_cast<uint32>(p[2]) << 16);
  }

  const uint8* data_;  // Character data.
  const bool free_on_delete_;
  const uint8* bitmaps_;
  uint32 from_;
  uint32 to_;
  const char* font_name_;
  const char* copyright_;
};

class Font : public SimpleResource {
 public:
   TAG(Font);
   Font(SimpleResourceGroup* group)
     : SimpleResource(group),
       _blocks(null),
       _block_count(0) {
     for (int i = 0; i < _CACHE_SIZE; i++) _cache[i] = null;
   }

   ~Font() {
     for (int i = 0; i < _block_count; i++) {
       delete _blocks[i];
     }
     delete _blocks;
     _blocks = null;
   }

   // Returns false on allocation error.
   bool add(const FontBlock* block) {
     const FontBlock** blocks = _new FontBlock const*[_block_count + 1];
     if (!blocks) return false;
     for (int i = 0; i < _block_count; i++) {
       blocks[i] = _blocks[i];
     }
     blocks[_block_count] = block;
     delete[] _blocks;
     _blocks = blocks;
     _block_count++;
     return true;
   }

 private:
   // Null terminated array of block pointers.
   const FontBlock* const* _blocks;
   int _block_count;
   static const int _CACHE_SIZE = 32;
   static const int _CACHE_GRANULARITY_BITS = 3;
   static const int _CACHE_GRANULARITY = 1 << _CACHE_GRANULARITY_BITS;
   static const int _CACHE_MASK = ~(_CACHE_GRANULARITY - 1);
   const FontCharacter* _cache[_CACHE_SIZE];

 public:
  const FontCharacter* get_char(int cp, bool substitute_mojibake=true);

 private:
  // Checks whether we have found the correct section (range of 16 code
  // points) for a given code point.
  bool _does_section_match(const FontCharacter* entry, int code_point) {
    if (entry == null) return false;
    return (entry->code_point() & _CACHE_MASK) == (code_point & _CACHE_MASK);
  }

  // For cache misses, find the index of the section of the byte array (a range
  // of 16 code points) that can contain the given code point.  These section
  // indexes are cached so we don't have to step through the entire byte array
  // to find the glyph for a given code point.
  const FontCharacter* _get_section_for_code_point(int code_point);
};

class BytemapDecompresser {
 public:
  virtual void compute_next_line() = 0;
  virtual const uint8* line() const = 0;
  virtual const uint8* opacity_line() const = 0;
};

class BitmapDecompresser {
 public:
  virtual void compute_next_line() = 0;
  virtual const uint8* line() const = 0;
};

class FontDecompresser : public BitmapDecompresser {
 public:
  FontDecompresser(int width, int height, const uint8* data)
      : _width(width)
      , _control_position(0)
      , _control_bits(data)
      , _saved_sames(0) {
    memset(line_, 0, sizeof(line_));
  }

  // Gets the next line of image data and puts it in line[].
  virtual void compute_next_line();

  virtual const uint8* line() const { return line_; }

  static const int NEW = 0;          // 00         One literal byte of new pixel data follows.
  static const int SAME_1 = 1;       // 01         Copy a byte directly from the line above.
  static const int PREFIX_2 = 2;     // 10         Prefix.
  static const int SAME_4_7 = 0;     // 10 00 xx     Copy 4-7 bytes.
  static const int GROW_RIGHT = 1;   // 10 01        Copy one byte.
  static const int RIGHT = 2;        // 10 10        Use the previous byte, shifted right one.
  static const int PREFIX_2_3 = 3;   // 10 11        Prefix.
  static const int SAME_10_25 = 0;   // 10 11 00 xx xx  Copy 10-25 bytes.
  static const int LO_BIT = 1;       // 10 11 01       0x01
  static const int HI_BIT = 2;       // 10 11 10       0x80
  static const int GROW = 3;         // 10 11 11       Add one black pixel on each side
  static const int PREFIX_3 = 3;     // 11         Prefix.
  static const int LEFT = 0;         // 11 00        Use the previous byte, shifted left one.
  static const int GROW_LEFT = 1;    // 11 01        Add one black pixel on the left of each run.
  static const int ZERO = 2;         // 11 10        Use all-zero bits for this byte.
  static const int PREFIX_3_3 = 3;   // 11 11        Prefix.
  static const int SHRINK_LEFT = 0;  // 11 11 00       Remove one black pixel on the left of each run.
  static const int SHRINK_RIGHT = 1; // 11 11 01       Remove one black pixel on the left of each run.
  static const int SHRINK = 2;       // 11 11 10       Remove one black pixel on each side.
  static const int ONES = 3;         // 11 11 11       Use all-one bits for this byte.

 private:
  uint8 line_[32];

  int _width;
  int _control_position;
  const uint8* _control_bits;
  int _saved_sames;

  int _command(int index) {
    return ((_control_bits[index >> 2] << ((index & 3) * 2)) >> 6) & 3;
  }
};

extern void iterate_font_characters(Blob string, Font* font, const std::function<void (const FontCharacter*)>& f);

} // namespace toit
