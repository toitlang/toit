// Copyright (C) 2020 Toitware ApS.
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

#include "nano_zlib.h"

namespace toit {

void ZlibRle::output_byte(uint8 b) {
  // Sanity check that we are not overflowing the buffer.  This 'if' should
  // always be true.
  if (output_index_ != output_limit_) {
    output_buffer_[output_index_++] = b;
  }
}

void ZlibRle::set_output_buffer(uint8* buffer, word index, word limit) {
  output_buffer_ = buffer;
  output_index_ = index;
  output_limit_ = limit;
}

word ZlibRle::get_output_index() { return output_index_; }

word ZlibRle::add(const uint8* contents, intptr_t extra) {
  if (!initialized_) {
    partial_ = 0b011;    // 1 = last block, 01 = fixed huffman block.
    partial_bits_ = 3;   // 3 bits in output buffer.
    initialized_ = true;
  }
  for (intptr_t i = 0; i < extra; i++) {
    // If the output buffer is getting fullish, return now.
    if (output_limit_ - output_index_ < 16) {
      return i;
    }
    uint8 b = contents[i];
    if (b == last_byte_) {
      repetitions_++;
      // We can max output 257 repetitions.  If the number gets too high then
      // flush a bit to limit how much data we will want to output later, but
      // don't leave less than 3, because there are no codes for a repetition
      // of 1 or 2 and it has to be done in a more verbose way.
      if (repetitions_ >= 260) output_repetitions();
    } else {
      while (repetitions_ != 0) output_repetitions();
      last_byte_ = b;
      literal(b);
    }
  }
  return extra;
}

static inline uint8 reverse_7(uint8 b) {
  return Utils::reverse_8(b << 1);
}

void ZlibRle::literal(uint8 byte) {
  if (byte < 0x90) {
    output_bits(Utils::reverse_8(0b00110000 + byte), 8);
  } else {
    // We don't have a reverse_9 so output the initial 1-bit first.
    output_bits(0b1, 1);
    output_bits(Utils::reverse_8(0b10010000 + byte - 0x90), 8);
  }
}

void ZlibRle::finish() {
  while (repetitions_ != 0) output_repetitions();
  output_bits(0b0000000, 7);  // End of block.
  while (partial_bits_ > 0) {
    output_byte(partial_ & 0xff);
    partial_bits_ -= 8;
    partial_ >>= 8;
  }
}

void ZlibRle::output_repetitions() {
  if (repetitions_ == 0) return;
  if (repetitions_ < 3) {
    for (int i = 0; i < repetitions_; i++) literal(last_byte_);
    repetitions_ = 0;
    return;
  }
  // Deflate can only represent up to 257 length in a regular way.
  int r = Utils::min(257, repetitions_);
  repetitions_ -= r;
  while (repetitions_ != 0 && repetitions_ < 3 && r > 3) {
    // We prefer not to output a repetition of 1 or 2 at the end, since that is verbose.
    r--;
    repetitions_++;
  }
  if (r <= 10) {
    output_bits(reverse_7(1 + r - 3), 7);  // Codes 1-8 inclusive indicate 3-10 repetitions.
  } else {
    r -= 3;  // Boundaries between encodings are now on bit boundaries: 8-15, 16-31, 32-63...
    int extra_bits_count = 29 - __builtin_clz(r);  // For 8-15, clz returns 28, for 16-31 clz returns 27.
    ASSERT(1 <= extra_bits_count && extra_bits_count <= 5);
    int extra_bits = r & ((1 << extra_bits_count) - 1);
    // Get a number 0-3 that is added to the length code.
    int two_bits = (r >> extra_bits_count) & 3;
    // Length code is 265-284.
    int code = 261 + (extra_bits_count << 2) + two_bits;
    if (code < 280) {
      // Length codes from 256-279 are Huffman encoded as 7 bit encodings starting at 0.
      output_bits(reverse_7(code - 256), 7);
    } else {
      // Length codes from 280- are Huffman encoded as 8 bit encodings starting at 0b11000000.
      output_bits(Utils::reverse_8(0b11000000 + code - 280), 8);
    }
    // Extra length bits are emitted verbatim after the length code.
    output_bits(extra_bits, extra_bits_count);
  }
  output_bits(0b00000, 5);              // Distance is zero.
}

void ZlibRle::output_bits(uint32 bits, int bit_count) {
  ASSERT(bit_count <= 24);
  ASSERT((bit_count == 0 && bits == 0) || ((int)bits < (1 << bit_count)));
  partial_ |= bits << partial_bits_;
  partial_bits_ += bit_count;
  while (partial_bits_ >= 8) {
    output_byte(partial_ & 0xff);
    partial_bits_ -= 8;
    partial_ = partial_ >> 8;
  }
}

}
