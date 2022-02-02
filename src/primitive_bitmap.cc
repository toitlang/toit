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

// Support routines for bitmapped images.  The format is compatible with the
// SSD1306 128x64 monochrome display.

#include "top.h"

#include "process.h"
#include "objects.h"
#include "objects_inline.h"
#include "primitive_font.h"
#include "primitive.h"

#include <stdlib.h>  // For abs().

namespace toit {

MODULE_IMPLEMENTATION(bitmap, MODULE_BITMAP)

PRIMITIVE(byte_zap) {
  ARGS(MutableBlob, bytes, int, value);
  memset(bytes.address(), value, bytes.length());
  return Smi::from(bytes.length());
}

static const int OVERWRITE = 0;
static const int OR = 1;
static const int ADD = 2;
static const int ADD_16_LE = 3;
static const int AND = 4;
static const int XOR = 5;
static const int NUMBER_OF_POSSIBLE_OPERATIONS = 6;

// Takes a rectangle from the src and copies it to a rectangle in the dest.
// The number of lines is determined by which data runs out first.
// All operations and stride distances are in bytes.
// After loading from the src, each byte is put through the lookup table,
//   rotated right by the given number of bits, anded with the mask, and then
//   either written to the destination or orred with the destination, depending
//   on the operation.
PRIMITIVE(blit) {
  ARGS(MutableBlob, dest, word, dest_pixel_stride, word, dest_line_stride,
       Blob,         src, word,  src_pixel_stride, word,  src_line_stride,
       word, pixels_per_line,
       Blob, lut,
       word, shift, word, mask, word, operation);
  // To avoid security issues caused by overflow, all values are limited to
  // positive 23 bits values.  We could up the limit on 64 bit, but this
  // would increase differences between device and server.
  if (operation < 0 || operation >= NUMBER_OF_POSSIBLE_OPERATIONS) OUT_OF_BOUNDS;
  word mask_23 = -0x800000;
  if (((dest_line_stride | src_line_stride | pixels_per_line) & mask_23) != 0) {
    INVALID_ARGUMENT;
  }
  // src_pixel_stride is multiplied by other values so to avoid security issues caused by
  // overflows it is limited to positive 7 bit values.
  word mask_7 = -0x80;
  if ((src_pixel_stride & mask_7) != 0) {
    INVALID_ARGUMENT;
  }
  // dest_pixel_stride is also multiplied by other values, but we allow negative values.
  if (!(-0x80 < dest_pixel_stride && dest_pixel_stride <= 0x80)) {
    INVALID_ARGUMENT;
  }
  word abs_dest_pixel_stride = abs(dest_pixel_stride);
  if (lut.length() < 0x100) INVALID_ARGUMENT;
  // Avoid infinite loop.
  if (dest_line_stride == 0 && src_line_stride == 0) INVALID_ARGUMENT;

  word src_offset = 0;
  word dest_offset = 0;
  word src_read_width = (pixels_per_line - 1) * src_pixel_stride;
  word dest_write_width = (pixels_per_line - 1) * abs_dest_pixel_stride;
  // 16 bit operation writes one more byte.
  if (abs_dest_pixel_stride != dest_pixel_stride) {
    // Too complicated to work out the bounds checking in this case.
    if (operation == ADD_16_LE) INVALID_ARGUMENT;
    // Start at the end of the 0th line when stepping backwards within each line.
    dest_offset += dest_write_width;
    // We can start each destination line right at the end of the blob, since
    // we will be stepping backwards.
    dest_write_width = 0;
  }
  if (operation == ADD_16_LE) dest_write_width++;
  while (src_offset + src_read_width < src.length() &&
         dest_offset + dest_write_width < dest.length()) {
    word src_index = src_offset;
    word dest_index = dest_offset;
    for (word x = 0; x < pixels_per_line; x++, src_index += src_pixel_stride, dest_index += dest_pixel_stride) {
      uint8_t pixel = src.address()[src_index];
      uint16_t looked_up = lut.address()[pixel];
      looked_up |= looked_up << 8;
      looked_up >>= shift & 7;
      looked_up &= mask;
      // Ordered in approximate order of popularity - we might want to
      // move this 'if' outside the loop for a better speed/code size
      // tradeoff.
      if (operation == OVERWRITE) {
        dest.address()[dest_index] = looked_up;
      } else if (operation == OR) {
        dest.address()[dest_index] |= looked_up;
      } else if (operation == ADD) {
        uint16_t value = dest.address()[dest_index];
        value += looked_up;
        dest.address()[dest_index] = value > 0xff ? 0xff : value;
      } else if (operation == AND) {
        dest.address()[dest_index] &= looked_up;
      } else if (operation == XOR) {
        dest.address()[dest_index] ^= looked_up;
      } else {
        ASSERT(operation == ADD_16_LE);
        uint32_t value = Utils::read_unaligned_uint16(dest.address() + dest_index);
        value += looked_up;
        Utils::write_unaligned_uint16(dest.address() + dest_index, value > 0xffff ? 0xffff : value);
      }
    }
    src_offset += src_line_stride;
    dest_offset += dest_line_stride;
  }
  return process->program()->null_object();
}

struct DrawData {
 public:
  int x_base;
  int y_base;
  int color;
  int orientation;
  int byte_array_width;
  int byte_array_height;
  uint8* contents;

  DrawData(int x, int y, int c, int o, int w, int h, uint8* content)
    : x_base(x)
    , y_base(y)
    , color(c)
    , orientation(o)
    , byte_array_width(w)
    , byte_array_height(h)
    , contents(content) {}
};

// Draws from a bit-oriented source to a bit- or byte-oriented destination.
static void draw_orientation_0_180_helper(BitmapDecompresser& decompresser, const PixelBox& bit_box, const DrawData& capture, int sign, bool bytewise_output) {
#ifndef CONFIG_TOIT_BIT_DISPLAY
  if (!bytewise_output) return;
#endif
#ifndef CONFIG_TOIT_BYTE_DISPLAY
  if (bytewise_output) return;
#endif
  uint8* contents = capture.contents;
  int width = sign * bit_box.box_width();
  int height = sign * bit_box.box_height();
  int xoffset = sign * bit_box.box_xoffset();
  int yoffset = sign * bit_box.box_yoffset();
  int bottom = capture.y_base - yoffset;
  if (bottom > capture.byte_array_height) bottom = capture.byte_array_height;
  if (bottom < 0) bottom = -1;
  int top = capture.y_base - yoffset - height;
  if (sign < 0) {
    if (top <= bottom) return;
  } else {
    if (top >= bottom) return;
  }
  int left = capture.x_base + xoffset;
  int right = capture.x_base + xoffset + width;
  if (right >= capture.byte_array_width) right = capture.byte_array_width;
  if (right < 0) right = -1;
  for (int y = top; y != bottom; y += sign) {
    decompresser.compute_next_line();
    if (y >= 0 && y < capture.byte_array_height) {
      if (left * sign >= right * sign) break;
      int mask = 1 << (y & 7);
      int x_mask = 0x80;
      const uint8* uncompressed = decompresser.line();
      int y_index = (bytewise_output ? y : y >> 3) * capture.byte_array_width;
      for (int x = left; x != right; x += sign) {
        if (0 <= x && x < capture.byte_array_width) {
          int index = x + y_index;
          ASSERT(0 <= index && index < capture.byte_array_height * capture.byte_array_width / (bytewise_output ? 1 : 8));
          if ((*uncompressed & x_mask) != 0) {
            if (bytewise_output) {
              contents[index] = capture.color;
            } else {
              if (capture.color) {
                contents[index] |= mask;
              } else {
                contents[index] &= ~mask;
              }
            }
          }
        }
        x_mask >>= 1;
        if (x_mask == 0) {
          x_mask = 0x80;
          uncompressed++;
        }
      }
    }
  }
}

static void SOMETIMES_UNUSED draw_text_orientation_0_180(int x_base, int y_base, int color, int orientation, Blob string, Font* font, uint8* contents, int byte_array_width, int byte_array_height, const bool bytewise_output) {
#ifndef CONFIG_TOIT_BIT_DISPLAY
  if (!bytewise_output) return;
#endif
#ifndef CONFIG_TOIT_BYTE_DISPLAY
  if (bytewise_output) return;
#endif
  if (orientation == 180) {
    // When stepping backwards the exclusive/inclusive bounds are swapped, so
    // adjust by one.
    x_base--;
    y_base--;
  }
  // If you capture too many variables, then the functor does heap allocations.
  DrawData capture(x_base, y_base, color, orientation, byte_array_width, byte_array_height, contents);
  iterate_font_characters(string, font, [&](const FontCharacter* c) {
    int sign = capture.orientation == 0 ? 1 : -1;
    if (c->box_height_ != 0) {
      FontDecompresser decompresser(c->box_width_, c->box_height_, c->bitmap());
      FontCharacterPixelBox bit_box(c);
      draw_orientation_0_180_helper(decompresser, bit_box, capture, sign, bytewise_output);
    }
    capture.x_base += sign * c->pixel_width;
  });
}

// Draws from a byte-oriented source to a byte-oriented destination.
static void draw_orientation_0_180_byte_helper(BytemapDecompresser& decompresser, const PixelBox& bit_box, const DrawData& capture, int sign) {
  uint8* contents = capture.contents;
  int width = sign * bit_box.box_width();
  int height = sign * bit_box.box_height();
  int xoffset = sign * bit_box.box_xoffset();
  int yoffset = sign * bit_box.box_yoffset();
  int bottom = capture.y_base - yoffset;
  if (bottom > capture.byte_array_height) bottom = capture.byte_array_height;
  if (bottom < 0) bottom = -1;
  int top = capture.y_base - yoffset - height;
  if (sign < 0) {
    if (top <= bottom) return;
  } else {
    if (top >= bottom) return;
  }
  int left = capture.x_base + xoffset;
  int right = capture.x_base + xoffset + width;
  if (right >= capture.byte_array_width) right = capture.byte_array_width;
  if (right < 0) right = -1;
  for (int y = top; y != bottom; y += sign) {
    decompresser.compute_next_line();
    if (y >= 0 && y < capture.byte_array_height) {
      if (left * sign >= right * sign) break;
      const uint8* uncompressed = decompresser.line();
      const uint8* opacity = decompresser.opacity_line();
      int y_index = y * capture.byte_array_width;
      for (int x = left; x != right; x += sign) {
        if (0 <= x && x < capture.byte_array_width) {
          int index = x + y_index;
          ASSERT(0 <= index && index < capture.byte_array_height * capture.byte_array_width);
          int opaque = *opacity;
          if (opaque == 0xff) {
            contents[index] = *uncompressed;
          } else if (opaque != 0) {
            contents[index] = (opaque * *uncompressed + (255 - opaque) * contents[index]) >> 8;
          }
        }
        uncompressed++;
        opacity++;
      }
    }
  }
}

// Draws from a bit-oriented source to a byte-oriented destination.
static void byte_draw_orientation_90_270_helper(BitmapDecompresser& decompresser, const PixelBox& bit_box, const DrawData& capture, int sign) {
  uint8* contents = capture.contents;
  int width = sign * bit_box.box_width();
  int height = sign * bit_box.box_height();
  int xoffset = sign * bit_box.box_xoffset();
  int yoffset = sign * bit_box.box_yoffset();
  if (bit_box.box_height() == 0) return;
  int bottom = Utils::max(-1, Utils::min(capture.byte_array_width, capture.x_base + yoffset));
  int top = capture.x_base + yoffset + height;
  if (sign < 0) {
    if (top >= bottom) return;
  } else {
    if (top <= bottom) return;
  }
  int left = capture.y_base + xoffset;
  int right = capture.y_base + xoffset + width;
  if (right >= capture.byte_array_height) {
    if (left >= capture.byte_array_height) return;
    right = capture.byte_array_height;
  }
  if (right < 0) {
    if (left < 0) return;
    right = -1;
  }
  for (int y = top; y != bottom; y -= sign) {
    int idx = left * capture.byte_array_width + y;
    decompresser.compute_next_line();
    if (y >= 0 && y < capture.byte_array_width) {
      int x_mask = 0x80;
      const uint8* uncompressed = decompresser.line();
      for (int x = left; x != right; x += sign) {
        if (0 <= x && x < capture.byte_array_height) {
          if ((*uncompressed & x_mask) != 0) {
            contents[idx] = capture.color;
          }
        }
        x_mask >>= 1;
        if (x_mask == 0) {
          x_mask = 0x80;
          uncompressed++;
        }
        idx += sign * capture.byte_array_width;
      }
    }
  }
}

// Draws from a byte-oriented source to a byte-oriented destination.
static void byte_draw_orientation_90_270_byte_helper(BytemapDecompresser& decompresser, const PixelBox& bit_box, const DrawData& capture, int sign) {
  uint8* contents = capture.contents;
  int width = sign * bit_box.box_width();
  int height = sign * bit_box.box_height();
  int xoffset = sign * bit_box.box_xoffset();
  int yoffset = sign * bit_box.box_yoffset();
  if (bit_box.box_height() == 0) return;
  int bottom = Utils::max(-1, Utils::min(capture.byte_array_width, capture.x_base + yoffset));
  int top = capture.x_base + yoffset + height;
  if (sign < 0) {
    if (top >= bottom) return;
  } else {
    if (top <= bottom) return;
  }
  int left = capture.y_base + xoffset;
  int right = capture.y_base + xoffset + width;
  if (right >= capture.byte_array_height) {
    if (left >= capture.byte_array_height) return;
    right = capture.byte_array_height;
  }
  if (right < 0) {
    if (left < 0) return;
    right = -1;
  }
  for (int y = top; y != bottom; y -= sign) {
    int idx = left * capture.byte_array_width + y;
    decompresser.compute_next_line();
    if (y >= 0 && y < capture.byte_array_width) {
      const uint8* uncompressed = decompresser.line();
      const uint8* opacity = decompresser.opacity_line();
      for (int x = left; x != right; x += sign) {
        if (0 <= x && x < capture.byte_array_height) {
          int opaque = *opacity;
          if (opaque == 0xff) {
            contents[idx] = *uncompressed;
          } else if (opaque != 0) {
            contents[idx] = (opaque * *uncompressed + (255 - opaque) * contents[idx]) >> 8;
          }
        }
        uncompressed++;
        opacity++;
        idx += sign * capture.byte_array_width;
      }
    }
  }
}

// Orientation 90 (bottom to top) and 270 (top to bottom).
static void SOMETIMES_UNUSED byte_draw_text_orientation_90_270(int x_base, int y_base, int color, int orientation, Blob string, Font* font, uint8* contents, int byte_array_width, int byte_array_height) {
  // When stepping backwards the exclusive/inclusive bounds are swapped, so
  // adjust by one.
  if (orientation == 90) {
    y_base--;
  } else {
    x_base--;
  }
  DrawData capture(x_base, y_base, color, orientation, byte_array_width, byte_array_height, contents);
  iterate_font_characters(string, font, [&](const FontCharacter* c) {
    FontDecompresser decompresser(c->box_width_, c->box_height_, c->bitmap());
    FontCharacterPixelBox bit_box(c);
    int sign = capture.orientation == 90 ? -1 : 1;  // -1 is bottom to top, 1 is top to bottom.
    byte_draw_orientation_90_270_helper(decompresser, bit_box, capture, sign);
    capture.y_base += sign * c->pixel_width;
  });
}

// Draws from a bit-oriented source to a byte-oriented destination.
static void draw_orientation_90_helper(BitmapDecompresser& decompresser, const PixelBox& bit_box, const DrawData& capture) {
  uint8* contents = capture.contents;
  int bottom = capture.x_base - bit_box.box_yoffset();
  if (bottom > capture.byte_array_width) bottom = capture.byte_array_width;
  int top = capture.x_base - bit_box.box_yoffset() - bit_box.box_height();
  int bytes_per_row = (bit_box.box_width() + 7) >> 3;
  for (int y = top; y < bottom; y++) {
    decompresser.compute_next_line();
    if (y >= 0) {
      const uint8* uncompressed = decompresser.line();
      int x = capture.y_base - bit_box.box_xoffset();
      for (int i = 0; i < bytes_per_row; i++) {
        if (x < capture.byte_array_height + 8 && x >= 0) {
          // Index of the leftmost pixel in the character.
          int index = y + ((x >> 3) * capture.byte_array_width);
          int low = x & 7;
          // Draw left-most pixel (and others in that byte of frame buffer.
          if (x < capture.byte_array_height) {
            uint8 b = uncompressed[i] >> (7 - low);
            if (capture.color) {
              contents[index] |= b;
            } else {
              contents[index] &= ~b;
            }
          }
          // Draw right-most pixel (and others in that byte of frame buffer.
          if (low != 7 && x >= 8) {
            uint8 b = uncompressed[i] << (1 + low);
            if (capture.color) {
              contents[index - capture.byte_array_width] |= b;
            } else {
              contents[index - capture.byte_array_width] &= ~b;
            }
          }
        }
        x -= 8;
      }
    }
  }
}

static void SOMETIMES_UNUSED draw_text_orientation_90(int x_base, int y_base, int color, Blob string, Font* font, uint8* contents, int byte_array_width, int byte_array_height) {
  // x and y are still relative to the string, not the screen.
  // When stepping backwards the exclusive/inclusive bounds are swapped, so
  // adjust by one.
  y_base--;
  int orientation = 90;
  DrawData capture(x_base, y_base, color, orientation, byte_array_width, byte_array_height, contents);
  iterate_font_characters(string, font, [&](const FontCharacter* c) {
    if (c->box_height_ != 0) {
      FontDecompresser decompresser(c->box_width_, c->box_height_, c->bitmap());
      FontCharacterPixelBox bit_box(c);
      draw_orientation_90_helper(decompresser, bit_box, capture);
    }
    capture.y_base -= c->pixel_width;
  });
}

// Draws from a bit-oriented source to a byte-oriented destination.
static void SOMETIMES_UNUSED draw_orientation_270_helper(BitmapDecompresser& decompresser, const PixelBox& bit_box, const DrawData& capture) {
  uint8* contents = capture.contents;
  int bottom = capture.x_base + bit_box.box_yoffset();
  if (bottom < 0) bottom = -1;
  int top = capture.x_base + bit_box.box_yoffset() + bit_box.box_height();
  int bytes_per_row = (bit_box.box_width() + 7) >> 3;
  for (int y = top; y > bottom; y--) {
    decompresser.compute_next_line();
    if (y < capture.byte_array_width) {
      const uint8* uncompressed = decompresser.line();
      int x = capture.y_base + bit_box.box_xoffset();
      for (int i = 0; i < bytes_per_row; i++) {
        if (x < capture.byte_array_height && x > -8) {
          // Index of the leftmost pixel in the character.
          int index = y + ((x >> 3) * capture.byte_array_width);
          int low = x & 7;
          uint8 d = uncompressed[i];
          d = Utils::reverse_8(d);
          // Draw left-most pixel (and others in that byte of frame buffer.
          if (x >= 0) {
            ASSERT(index >= 0 && index < (capture.byte_array_height * capture.byte_array_width / 8));
            uint8 b = d << low;
            if (capture.color) {
              contents[index] |= b;
            } else {
              contents[index] &= ~b;
            }
          }
          // Draw right-most pixel (and others in that byte of frame buffer.
          if (low != 0 && x < capture.byte_array_height - 8) {
            ASSERT(index + capture.byte_array_width >= 0 && index + capture.byte_array_width < (capture.byte_array_height * capture.byte_array_width / 8));
            uint8 b = d >> (8 - low);
            if (capture.color) {
              contents[index + capture.byte_array_width] |= b;
            } else {
              contents[index + capture.byte_array_width] &= ~b;
            }
          }
        }
        x += 8;
      }
    }
  }
}

static void SOMETIMES_UNUSED draw_text_orientation_270(int x_base, int y_base, int color, Blob string, Font* font, uint8* contents, int byte_array_width, int byte_array_height) {
  // x and y are still relative to the string, not the screen.
  // When stepping backwards the exclusive/inclusive bounds are swapped, so
  // adjust by one.
  x_base--;
  int orientation = 270;
  DrawData capture(x_base, y_base, color, orientation, byte_array_width, byte_array_height, contents);
  iterate_font_characters(string, font, [&](const FontCharacter* c) {
    if (c->box_height_ != 0) {
      FontDecompresser decompresser(c->box_width_, c->box_height_, c->bitmap());
      FontCharacterPixelBox bit_box(c);
      draw_orientation_270_helper(decompresser, bit_box, capture);
    }
    capture.y_base += c->pixel_width;
  });
}

PRIMITIVE(draw_text) {
#ifndef CONFIG_TOIT_BIT_DISPLAY
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(int, x_base, int, y_base, int, color, int, orientation, StringOrSlice, string, Font, font, MutableBlob, bytes, int, byte_array_width);
  // The byte array is arranged as n pages, each byte_array_width x 8.  Each
  // page is one byte per column.  Each column has the most significant bit at
  // the bottom, the least significant at the top.  Y coordinates are 0 at the
  // top.
  if (byte_array_width < 1) OUT_OF_BOUNDS;
  int byte_array_height = bytes.length() / byte_array_width;
  if (byte_array_height * byte_array_width != bytes.length()) OUT_OF_BOUNDS;
  byte_array_height <<= 3;  // Height in pixels, not bytes.
  if ((byte_array_width & 7) != 0) OUT_OF_BOUNDS;
  if (!(0 <= orientation && orientation <= 3)) INVALID_ARGUMENT;

  uint8* contents = bytes.address();

  switch (orientation) {
    case 0:
    case 2:
      draw_text_orientation_0_180(x_base, y_base, color, orientation * 90, string, font, contents, byte_array_width, byte_array_height, false);
      break;
    case 1:
      draw_text_orientation_90(x_base, y_base, color, string, font, contents, byte_array_width, byte_array_height);
      break;
    case 3:
      draw_text_orientation_270(x_base, y_base, color, string, font, contents, byte_array_width, byte_array_height);
      break;
  }
  return process->program()->null_object();
#endif  // CONFIG_TOIT_BIT_DISPLAY
}

class BitmapPixelBox : public PixelBox {
 public:
  virtual int box_width() const { return width_; }
  virtual int box_height() const { return height_; }
  virtual int box_xoffset() const { return 0; }
  // Bitmaps extend below the origin, not above like fonts.
  virtual int box_yoffset() const { return -height_; }
  BitmapPixelBox(int width, int height) : width_(width), height_(height) {}

 private:
  int width_;
  int height_;
};

class BitmapSource : public BitmapDecompresser {
 public:
  BitmapSource(const uint8* p, int bytes_per_line) : p_(p - bytes_per_line), bytes_per_line_(bytes_per_line) {}

  virtual void compute_next_line() {
    p_ += bytes_per_line_;
  }

  virtual const uint8* line() const {
    return p_;
  }

 private:
  const uint8* p_;
  int bytes_per_line_;
};

/**
A pixel decompresser that uses an array of bytes as a source, and looks up each
  byte in an RGBRGB... palette before providing it to the drawing routine.
*/
class IndexedBytemapSource : public BytemapDecompresser {
 public:
  // After calling the constructor, out_of_memory must be checked on the
  // resulting object.
  IndexedBytemapSource(const uint8* pixels, word pixels_per_line, const uint8* palette, word palette_size, int transparent_color_index)
    : pixels_(pixels)
    , pixels_per_line_(pixels_per_line)
    , palette_(palette)
    , palette_size_(palette_size)
    , transparent_color_index_(transparent_color_index) {
    line_buffer_ = unvoid_cast<uint8*>(malloc(pixels_per_line_));
    opacity_buffer_ = unvoid_cast<uint8*>(malloc(pixels_per_line_));
  }

  ~IndexedBytemapSource() {
    free(line_buffer_);
    free(opacity_buffer_);
  }

  bool out_of_memory() {
    return line_buffer_ == null || opacity_buffer_ == null;
  }

  virtual void compute_next_line() {
    for (word i = 0; i < pixels_per_line_; i++) {
      uint8 color_index = *pixels_++;
      line_buffer_[i] = (color_index * 3 < palette_size_) ? palette_[color_index * 3] : color_index;
      opacity_buffer_[i] = color_index == transparent_color_index_ ? 0 : 0xff;
    }
  }

  virtual const uint8* line() const {
    return line_buffer_;
  }

  virtual const uint8* opacity_line() const {
    return opacity_buffer_;
  }

 private:
  const uint8* pixels_;
  word pixels_per_line_;
  const uint8* palette_;
  word palette_size_;
  int transparent_color_index_;
  uint8* line_buffer_;
  uint8* opacity_buffer_;
};

// Draw a bitmap on a bitmap or a bytemap.  The ones in the input bitmap are
// drawn in the given color and the zeros are transparent.
PRIMITIVE(draw_bitmap) {
#if !defined(CONFIG_TOIT_BIT_DISPLAY) && !defined(CONFIG_TOIT_BYTE_DISPLAY)
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(int, x_base, int, y_base, int, color, int, orientation, Blob, in_bytes, int, bitmap_offset, int, bitmap_width, MutableBlob, bytes, int, byte_array_width, bool, bytewise_output);
#ifndef CONFIG_TOIT_BIT_DISPLAY
  if (!bytewise_output) UNIMPLEMENTED_PRIMITIVE;
#endif
#ifndef CONFIG_TOIT_BYTE_DISPLAY
  if (bytewise_output) UNIMPLEMENTED_PRIMITIVE;
#endif
  // Bitwise output:
  //   The output byte array is arranged as n pages, each byte_array_width x 8.  Each
  //   page is one byte per column.  Each column has the most significant bit at
  //   the bottom, the least significant at the top.  Y coordinates are 0 at the
  //   top.
  //   The input byte array is arranged a line at a time from top to bottom.
  //   Each line is a whole number of big endian bytes, one bit per pixel, where
  //   1 means draw the color and 0 means transparent.
  // Bytewise output:
  //   The byte array is arranged as n rows, each byte_array_width long.
  if (byte_array_width < 1) OUT_OF_BOUNDS;
  int byte_array_height = bytes.length() / byte_array_width;
  if (byte_array_height * byte_array_width != bytes.length()) OUT_OF_BOUNDS;
  if (!bytewise_output) {
    byte_array_height <<= 3;  // Height in pixels, not bytes.
  }

  uint8* output_contents = bytes.address();

  int bytes_per_line = (bitmap_width + 7) >> 3;
  if (bitmap_offset < 0) OUT_OF_BOUNDS;
  if (bitmap_width < 1) OUT_OF_BOUNDS;
  int bitmap_height = (in_bytes.length() - bitmap_offset) / bytes_per_line;
  if (bitmap_height * bytes_per_line > in_bytes.length() - bitmap_offset) OUT_OF_BOUNDS;

  if (!(0 <= orientation && orientation <= 3)) INVALID_ARGUMENT;

  const uint8* input_contents = in_bytes.address() + bitmap_offset;

  DrawData capture(x_base, y_base, color, orientation * 90, byte_array_width, byte_array_height, output_contents);
  BitmapSource bitmap_source(input_contents, bytes_per_line);
  BitmapPixelBox bit_box(bitmap_width, bitmap_height);

  switch (orientation) {
    case 2: {
      // When stepping backwards the exclusive/inclusive bounds are swapped, so
      // adjust by one.
      capture.x_base--;
      capture.y_base--;
      int sign = -1;
      draw_orientation_0_180_helper(bitmap_source, bit_box, capture, sign, bytewise_output);
      break;
    }
    case 0: {
      int sign = 1;
      draw_orientation_0_180_helper(bitmap_source, bit_box, capture, sign, bytewise_output);
      break;
    }
    case 1:
      // When stepping backwards the exclusive/inclusive bounds are swapped, so
      // adjust by one.
      capture.y_base--;
      if (bytewise_output) {
        int sign = -1;
        byte_draw_orientation_90_270_helper(bitmap_source, bit_box, capture, sign);
      } else {
        draw_orientation_90_helper(bitmap_source, bit_box, capture);
      }
      break;
    case 3:
      // When stepping backwards the exclusive/inclusive bounds are swapped, so
      // adjust by one.
      capture.x_base--;
      if (bytewise_output) {
        int sign = 1;
        byte_draw_orientation_90_270_helper(bitmap_source, bit_box, capture, sign);
      } else {
        draw_orientation_270_helper(bitmap_source, bit_box, capture);
      }
      break;
  }
  return process->program()->null_object();
#endif  // !defined(CONFIG_TOIT_BIT_DISPLAY) && !defined(CONFIG_TOIT_BYTE_DISPLAY)
}

static void byte_draw(int, BytemapDecompresser&, const PixelBox&, DrawData&);

// Draw a bytemap on a bytemap.  A palette is given, where every third byte is used.
PRIMITIVE(draw_bytemap) {
  ARGS(int, x_base, int, y_base, int, transparent_color, int, orientation, Blob, in_bytes, int, bytes_per_line, Blob, palette, MutableBlob, bytes, int, byte_array_width);
  // Both the input and output byte arrays are arranged as n rows, each byte_array_width long.
  if (byte_array_width < 1) OUT_OF_BOUNDS;
  int byte_array_height = bytes.length() / byte_array_width;
  if (byte_array_height * byte_array_width != bytes.length()) OUT_OF_BOUNDS;

  uint8* output_contents = bytes.address();

  if (bytes_per_line < 1) OUT_OF_BOUNDS;
  int bitmap_height = in_bytes.length() / bytes_per_line;
  if (bitmap_height * bytes_per_line > in_bytes.length()) OUT_OF_BOUNDS;

  if (!(0 <= orientation && orientation <= 3)) INVALID_ARGUMENT;

  int color = 0;  // Unused.

  DrawData capture(x_base, y_base, color, orientation * 90, byte_array_width, byte_array_height, output_contents);
  IndexedBytemapSource bytemap_source(in_bytes.address(), bytes_per_line, palette.address(), palette.length(), transparent_color);
  if (bytemap_source.out_of_memory()) MALLOC_FAILED;

  BitmapPixelBox bit_box(bytes_per_line, bitmap_height);

  byte_draw(orientation, bytemap_source, bit_box, capture);

  return process->program()->null_object();
}

static void byte_draw(int orientation, BytemapDecompresser& decompresser, const PixelBox& bit_box, DrawData& capture) {
  switch (orientation) {
    case 2: {
      // When stepping backwards the exclusive/inclusive bounds are swapped, so
      // adjust by one.
      capture.x_base--;
      capture.y_base--;
      int sign = -1;
      draw_orientation_0_180_byte_helper(decompresser, bit_box, capture, sign);
      break;
    }
    case 0: {
      int sign = 1;
      draw_orientation_0_180_byte_helper(decompresser, bit_box, capture, sign);
      break;
    }
    case 1: {
      int sign = -1;
      // When stepping backwards the exclusive/inclusive bounds are swapped, so
      // adjust by one.
      capture.y_base--;
      byte_draw_orientation_90_270_byte_helper(decompresser, bit_box, capture, sign);
      break;
    }
    case 3: {
      int sign = 1;
      // When stepping backwards the exclusive/inclusive bounds are swapped, so
      // adjust by one.
      capture.x_base--;
      byte_draw_orientation_90_270_byte_helper(decompresser, bit_box, capture, sign);
      break;
    }
  }
}

PRIMITIVE(byte_draw_text) {
#ifndef CONFIG_TOIT_BYTE_DISPLAY
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(int, x_base, int, y_base, int, color, int, orientation, StringOrSlice, string, Font, font, MutableBlob, bytes, int, byte_array_width);
  // The byte array is arranged as n columns, each byte_array_width long.
  if (byte_array_width < 1) OUT_OF_BOUNDS;
  int byte_array_height = bytes.length() / byte_array_width;
  if (byte_array_height * byte_array_width != bytes.length()) OUT_OF_BOUNDS;

  if (!(0 <= orientation && orientation <= 3)) INVALID_ARGUMENT;

  uint8* contents = bytes.address();

  switch (orientation) {
    case 0:
    case 2:
      draw_text_orientation_0_180(x_base, y_base, color, orientation * 90, string, font, contents, byte_array_width, byte_array_height, true);
      break;
    case 1:
    case 3:
      byte_draw_text_orientation_90_270(x_base, y_base, color, orientation * 90, string, font, contents, byte_array_width, byte_array_height);
      break;
  }
  return process->program()->null_object();
#endif  // TOIT BYTE_DISPLAY
}

PRIMITIVE(rectangle) {
#ifndef CONFIG_TOIT_BIT_DISPLAY
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(int, x_base, int, y_base, int, color, int, width, int, height, MutableBlob, bytes, int, byte_array_width);
  if (byte_array_width < 1) OUT_OF_BOUNDS;
  int byte_array_height = bytes.length() / byte_array_width;
  if (byte_array_height * byte_array_width != bytes.length()) OUT_OF_BOUNDS;
  byte_array_height <<= 3;  // Height in pixels, not bytes.
  if (width < 0 || height < 0) OUT_OF_RANGE;
  static const int TOO_BIG = 0x8000000;
  if (x_base > TOO_BIG || y_base > TOO_BIG || width > TOO_BIG || height > TOO_BIG || -x_base > TOO_BIG || -y_base > TOO_BIG) {
    OUT_OF_RANGE;
  }
  if (x_base >= byte_array_width || y_base >= byte_array_height || x_base + width <= 0 || y_base + height <= 0 || height == 0 || width == 0) {
    return process->program()->null_object();
  }
  if (x_base < 0) {
    width += x_base;
    x_base = 0;
  }
  if (y_base < 0) {
    height += y_base;
    y_base = 0;
  }
  if (x_base + width > byte_array_width) {
    width = byte_array_width - x_base;
  }
  if (y_base + height  > byte_array_height) {
    height = byte_array_height - y_base;
  }
  uint8* contents = bytes.address();
  while (height > 0) {
    int page = y_base >> 3;
    int end_page = (y_base + height - 1) >> 3;
    int mask = (0xff << (y_base & 7));
    if (page == end_page) {
      mask &= 0xff >> (7 - ((y_base + height - 1) & 7));
    }
    uint8* end = contents + (page * byte_array_width) + x_base + width;
    if (color) {
      for (uint8* p = contents + (page * byte_array_width) + x_base; p < end; p++) {
        *p |= mask;
      }
    } else {
      mask = ~mask;
      for (uint8* p = contents + (page * byte_array_width) + x_base; p < end; p++) {
        *p &= mask;
      }
    }
    if (page == end_page) {
      return process->program()->null_object();
    }
    int new_y_base = (y_base + 8) & ~7;
    int step = new_y_base - y_base;
    height -= step;
    y_base = new_y_base;
  }
  return process->program()->null_object();
#endif  // CONFIG_TOIT_BIT_DISPLAY
}

PRIMITIVE(byte_rectangle) {
#ifndef CONFIG_TOIT_BYTE_DISPLAY
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(int, x_base, int, y_base, int, color, int, width, int, height, MutableBlob, bytes, int, byte_array_width);
  if (byte_array_width < 1) OUT_OF_BOUNDS;
  int byte_array_height = bytes.length() / byte_array_width;
  if (byte_array_height * byte_array_width != bytes.length()) OUT_OF_BOUNDS;
  if (width < 0 || height < 0) OUT_OF_RANGE;
  static const int TOO_BIG = 0x8000000;
  if (x_base > TOO_BIG || y_base > TOO_BIG || width > TOO_BIG || height > TOO_BIG || -x_base > TOO_BIG || -y_base > TOO_BIG) {
    OUT_OF_RANGE;
  }
  if (x_base >= byte_array_width || y_base >= byte_array_height || x_base + width <= 0 || y_base + height <= 0 || height == 0 || width == 0) {
    return process->program()->false_object();
  }
  if (x_base < 0) {
    width += x_base;
    x_base = 0;
  }
  if (y_base < 0) {
    height += y_base;
    y_base = 0;
  }
  if (x_base + width > byte_array_width) {
    width = byte_array_width - x_base;
  }
  if (y_base + height  > byte_array_height) {
    height = byte_array_height - y_base;
  }
  uint8* contents = bytes.address() + x_base + y_base * byte_array_width;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      contents[x] = color;
    }
    contents += byte_array_width;
  }
  return process->program()->true_object();
#endif  // CONFIG_TOIT_BYTE_DISPLAY
}

// Coefficients for Gaussian blur at various sizes.  They are all
// made to add up to powers of two, for fixed point arithmetic.
static const uint16_t SOMETIMES_UNUSED coefficients[] = {
  1, 2, 1,
  1, 4, 6, 4, 1,
  1, 6, 15, 20, 15, 6, 1,
  1, 8, 28, 56, 70, 56, 28, 8, 1,
  1, 10, 45, 120, 210, 252, 210, 120, 45, 10, 1,
  1, 12, 66, 220, 495, 792, 924, 792, 495, 220, 66, 12, 1,
  1, 14, 91, 364, 1001, 2002, 3003, 3432, 3003, 2002, 1001, 364, 91, 14, 1};

// Offsets where the coefficients for various sizes start in the coefficients
// array.
static const int MAX_RADIUS = 8;
static const uint16_t SOMETIMES_UNUSED start_index_for_radius[MAX_RADIUS - 1] = {0, 3, 8, 15, 24, 35, 48};

// Perform Gaussian blur on a byte-per-pixel pixmap.  Pixels that are closer to
// the edge than the blur radius will not contain a meaningful result, so the
// pixmap should be padded and then trimmed afterwards.
PRIMITIVE(bytemap_blur) {
#ifndef CONFIG_TOIT_BYTE_DISPLAY
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(MutableBlob, bytes, int, width, int, x_blur_radius, int, y_blur_radius);
  uint8* image = bytes.address();
  if (width < 1) OUT_OF_BOUNDS;
  int height = bytes.length() / width;
  if (height * width != bytes.length()) OUT_OF_BOUNDS;
  if (x_blur_radius < 2 && y_blur_radius < 2) return process->program()->null_object();
  if (x_blur_radius < 0 || y_blur_radius < 0) INVALID_ARGUMENT;
  const int BUFFER_SIZE = 16;  // Power of 2.
  const int BUFFER_MASK = BUFFER_SIZE - 1;
  if (x_blur_radius >= MAX_RADIUS - 1 || x_blur_radius * 2 > BUFFER_SIZE) OUT_OF_BOUNDS;
  if (y_blur_radius >= MAX_RADIUS - 1 || y_blur_radius * 2 > BUFFER_SIZE) OUT_OF_BOUNDS;
  // We can't immediately write the blurred pixel back because we need its
  // original value to blur the adjacent pixels.  However we don't need to make
  // a copy of the whole image, just the recently blurred pixels.  This is where
  // we store that copy.
  uint8_t buffer[BUFFER_SIZE];
  // Gaussian blur has the nice property that you can perform it in each
  // direction separately and it has the same result as a much more expensive
  // nxn single-pass blur.
  // Blur in X direction.
  if (x_blur_radius > 1) {
    memset(buffer, 0, BUFFER_SIZE);
    int shift = (x_blur_radius - 1) * 2;
    int center = start_index_for_radius[x_blur_radius - 2] + x_blur_radius - 1;
    for (int y = 0; y < height; y++) {
      int image_index = y * width;
      for (int x = x_blur_radius - 1; x <= width - x_blur_radius; x++) {
        int coefficients_sum = 0;  // Only for the assert.
        int sum = 0;
        for (int i = -x_blur_radius + 1; i < x_blur_radius; i++) {
          uint32_t coefficient = coefficients[center + i];
          coefficients_sum += coefficient;
          sum += coefficient * image[image_index + x + i];
        }
        ASSERT(coefficients_sum == 1 << shift);  // Fixed point arithmetic requires this.
        USE(coefficients_sum);
        sum >>= shift;
        // Flush old pixels to the image.
        if (x - BUFFER_SIZE >= 0) image[image_index + x - BUFFER_SIZE] = buffer[x & BUFFER_MASK];
        buffer[x & BUFFER_MASK] = sum;
      }
      // Flush the rest of the pixels to the image.
      for (int x = Utils::max(0, width + 1 - x_blur_radius - BUFFER_SIZE); x <= width - x_blur_radius; x++) {
        image[image_index + x] = buffer[x & BUFFER_MASK];
      }
    }
  }
  // Blur in Y direction.
  if (y_blur_radius > 1) {
    memset(buffer, 0, BUFFER_SIZE);
    int shift = (y_blur_radius - 1) * 2;
    int center = start_index_for_radius[y_blur_radius - 2] + y_blur_radius - 1;
    for (int x = 0; x < width; x++) {
      for (int y = y_blur_radius - 1; y <= height - y_blur_radius; y++) {
        int image_index = (y - y_blur_radius + 1) * width + x;
        int sum = 0;
        for (int i = -y_blur_radius + 1; i < y_blur_radius; i++) {
          sum += (uint32_t)(coefficients[center + i]) * image[image_index];
          image_index += width;
        }
        sum >>= shift;
        if (y - BUFFER_SIZE >= 0) image[x + (y - BUFFER_SIZE) * width] = buffer[y & BUFFER_MASK];
        buffer[y & BUFFER_MASK] = sum;
      }
      int y = Utils::max(0, height + 1 - y_blur_radius - BUFFER_SIZE);
      for (int image_index = x + y * width; y <= height - y_blur_radius; y++) {
        image[image_index] = buffer[y & BUFFER_MASK];
        image_index += width;
      }
    }
  }
  return process->program()->null_object();
#endif  // CONFIG_TOIT_BYTE_DISPLAY
}

// Paints a framed window on top of a background that has already been
// rendered.  The frame can be partially transparent and so can the window
// contents.  The frame is painted on top of the background, then window
// contents are painted on top.
PRIMITIVE(composit) {
#if !defined(CONFIG_TOIT_BIT_DISPLAY) && !defined(CONFIG_TOIT_BYTE_DISPLAY)
  UNIMPLEMENTED_PRIMITIVE;
#else
  ARGS(MutableBlob, dest_bytes, Blob, frame_opacity_object, Object, frame, Blob, painting_opacity_byte_array, Blob, painting, bool, bit);
#ifndef CONFIG_TOIT_BIT_DISPLAY
  if (bit) UNIMPLEMENTED_PRIMITIVE;
#endif
#ifndef CONFIG_TOIT_BYTE_DISPLAY
  if (!bit) UNIMPLEMENTED_PRIMITIVE;
#endif

  uint8* dest_address = dest_bytes.address();
  int dest_length = dest_bytes.length();

  // The frame opacity/transparency can be either an alpha map or a single opacity value.
  bool frame_opacity_lookup;
  int frame_opacity = 0;
  const uint8* frame_opacity_bytes = frame_opacity_object.address();
  int frame_opacity_length = frame_opacity_object.length();
  if (frame_opacity_length == 1) {
    frame_opacity_lookup = false;
    frame_opacity = frame_opacity_bytes[0];
  } else {
    frame_opacity_lookup = true;
    if (frame_opacity_length != dest_length) OUT_OF_BOUNDS;
  }

  // The painting opacity/transparency can be either an alpha map or a single opacity value.
  bool painting_opacity_lookup;
  int painting_opacity = 0;
  const uint8* painting_opacity_bytes = painting_opacity_byte_array.address();
  int painting_opacity_length = painting_opacity_byte_array.length();
  if (painting_opacity_length == 1) {
    painting_opacity_lookup = false;
    painting_opacity = painting_opacity_bytes[0];
  } else {
    painting_opacity_lookup = true;
    if (painting_opacity_length != dest_length) OUT_OF_BOUNDS;
  }

  // Unless the frame is totally transparent (opacity 0) we need some frame
  // pixels to mix in.
  const uint8* frame_pixels;
  int frame_length;
  if (!frame->byte_content(process->program(), &frame_pixels, &frame_length, STRINGS_OR_BYTE_ARRAYS)) {
    if (frame_opacity != 0) WRONG_TYPE;
  } else {
    if (frame_length != dest_length) OUT_OF_BOUNDS;
  }

  const uint8* painting_pixels = painting.address();
  int painting_length = painting.length();
  // The painting (window contents) must always be in the form of pixels.
  if (painting_length != dest_length) OUT_OF_BOUNDS;

  if (bit) {
    // Bit version.  The images and opacities are all in a 1-bit-per-pixel format.
    for (int i = 0; i < dest_length; i++) {
      int frame_mask = frame_opacity_lookup ? frame_opacity_bytes[i] : frame_opacity;
      int painting_mask = painting_opacity_lookup ? painting_opacity_bytes[i] : painting_opacity;
      if (painting_mask == 0xff) {
        // Window area.
        dest_address[i] = painting_pixels[i];
      } else {
        if (frame_mask == 0) {
          dest_address[i] = (dest_address[i] & ~painting_mask) | (painting_pixels[i] & painting_mask);
        } else {
          // Mix frame with background.
          int mix = (frame_pixels[i] & frame_mask) | (dest_address[i] & ~frame_mask);
          // Mix frame/background with window area.
          dest_address[i] = (painting_pixels[i] & painting_mask) | (mix & ~painting_mask);
        }
      }
    }
  } else {
    // Byte version.  Opacities are 0-255 and pixels are also bytes.
    for (int i = 0; i < dest_length; i++) {
      int frame_factor = frame_opacity_lookup ? frame_opacity_bytes[i] : frame_opacity;
      int painting_factor = painting_opacity_lookup ? painting_opacity_bytes[i] : painting_opacity;
      if (painting_factor == 0xff) {
        // Window area.
        dest_address[i] = painting_pixels[i];
      } else {
        // Edge area.  First mix frame and background.
        int mix;
        if (frame_factor == 0xff) {
          mix = frame_pixels[i];
        } else if (frame_factor == 0) {
          mix = dest_address[i];
        } else {
          mix = (frame_pixels[i] * frame_factor + dest_address[i] * (255 - frame_factor)) >> 8;
        }
        // Now mix shaded background with window area.
        dest_address[i] = (painting_pixels[i] * painting_factor + mix * (255 - painting_factor)) >> 8;
      }
    }
  }
  return process->program()->null_object();
#endif // !defined(CONFIG_TOIT_BIT_DISPLAY) && !defined(CONFIG_TOIT_BYTE_DISPLAY)
}

}
