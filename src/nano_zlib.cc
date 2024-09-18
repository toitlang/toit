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

#ifdef CONFIG_TOIT_ZLIB_RLE
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
    if (mode_ == LITERAL) {
      // We need at least 4 bytes of lookahead to make compression decisions.
      if (unemitted_bytes_valid_ < 4) {
        unemitted_bytes_ <<= 8;
        unemitted_bytes_ |= b;
        unemitted_bytes_valid_++;
        continue;
      }
      if (last_bytes_valid_ >= 1 &&
          (last_bytes_ & 0xff) == (unemitted_bytes_ & 0xff) &&
          (last_bytes_ & 0xff) == ((unemitted_bytes_ >> 8) & 0xff) &&
          (unemitted_bytes_ >> 16) == (unemitted_bytes_ & 0xffff)) {
        // We recognized that the unemitted bytes all four matched the last
        // emitted one: last=...a unemitted=aaaa
        mode_ = REP1;
        bytes_repeated_ = 4;
        last_bytes_ = unemitted_bytes_;
        last_bytes_valid_ = 4;
        unemitted_bytes_ = 0;
        unemitted_bytes_valid_ = 0;
      } else if (last_bytes_valid_ >= 2 &&
          (last_bytes_ & 0xffff) == (unemitted_bytes_ & 0xffff) &&
          (unemitted_bytes_ >> 16) == (unemitted_bytes_ & 0xffff)) {
        // We recognized that the four unemitted bytes are two repetitions of
        // the last two emitted ones: last=..ab unemitted=abab
        mode_ = REP2;
        bytes_repeated_ = 4;
        last_bytes_ = unemitted_bytes_;
        last_bytes_valid_ = 4;
        unemitted_bytes_ = 0;
        unemitted_bytes_valid_ = 0;
      } else if (last_bytes_valid_ >= 1 &&
          (last_bytes_ & 0xff) == ((unemitted_bytes_ >> 8) & 0xff) &&
          (last_bytes_ & 0xff) == ((unemitted_bytes_ >> 16) & 0xff) &&
          (last_bytes_ & 0xff) == ((unemitted_bytes_ >> 24) & 0xff)) {
        // We recognized that the three first unemitted bytes are repetitions
        // of the last emitted one.  It's not a huge win to code them as
        // a run of 1+3, but it saves a few bits: last=...a unemitted=aaax
        mode_ = REP1;
        bytes_repeated_ = 3;
        last_bytes_ <<= 24;
        last_bytes_ |= unemitted_bytes_ >> 8;
        last_bytes_valid_ = 4;
        unemitted_bytes_ &= 0xff;
        unemitted_bytes_valid_ = 1;
        output_repetitions();  // Will flush completely since bytes_repeated_ == 3.
      } else if (last_bytes_valid_ >= 4 &&
          last_bytes_ == unemitted_bytes_) {
        // We recognized that the four unemitted bytes are the same as
        // the last four emitted ones: last=abcd unemitted=abcd
        mode_ = REP4;
        bytes_repeated_ = 4;
        unemitted_bytes_ = 0;
        unemitted_bytes_valid_ = 0;
      } else if (last_bytes_valid_ >= 3 &&
          (last_bytes_ & 0xffffff) == (unemitted_bytes_ >> 8)) {
        // We recognized that the first three of the unemitted bytes are
        // the same as the last three emitted ones: last=.abc unemitted=abc?
        mode_ = REP3;
        if ((unemitted_bytes_ & 0xff) == ((last_bytes_ >> 16) & 0xff)) {
          // The fourth unemitted byte also matches the pattern of three
          // being repeated: last=abc unemitted=abca
          last_bytes_ = unemitted_bytes_;
          last_bytes_valid_ = 4;
          bytes_repeated_ = 4;
          unemitted_bytes_ = 0;
          unemitted_bytes_valid_ = 0;
        } else {
          // The last unemitted byte didn't match, so it was a rather
          // short run: last=abc unemitted=abcx
          bytes_repeated_ = 3;
          last_bytes_ <<= 24;
          last_bytes_ |= unemitted_bytes_ >> 8;
          unemitted_bytes_ &= 0xff;
          unemitted_bytes_valid_ = 1;
          output_repetitions();  // Will flush completely since bytes_repeated_ == 3.
        }
      }
    }
    if (mode_ == LITERAL) {
      if (unemitted_bytes_valid_ == 4) {
        // We have no current run, so just emit the oldest unemitted byte to
        // make space for the new bytes.
        uint8 to_emit = unemitted_bytes_ >> 24;
        literal(to_emit);
        unemitted_bytes_ <<= 8;
        unemitted_bytes_ |= b;
        last_bytes_ <<= 8;
        last_bytes_ |= to_emit;
        if (last_bytes_valid_ < 4) last_bytes_valid_++;
      } else {
        // We have no current run, but there's a spare slot in the unemitted
        // bytes so we put our new byte there.
        unemitted_bytes_ <<= 8;
        unemitted_bytes_valid_++;
        unemitted_bytes_ |= b;
      }
    } else {
      // We have some sort of run going.  As long as it is running we don't
      // have unemitted bytes.
      ASSERT(unemitted_bytes_valid_ == 0);
      int shift = static_cast<int>(mode_ - 1) << 3;
      if (b == ((last_bytes_ >> shift) & 0xff)) {
        // Hooray, the new byte fits the run.
        bytes_repeated_++;
        if (last_bytes_valid_ < 4) {
          last_bytes_valid_++;
        }
        last_bytes_ <<= 8;
        last_bytes_ |= b;
      } else {
        // Sadly, the run has ended.
        ASSERT(bytes_repeated_ >= 3);
        output_repetitions(true);   // Will flush completely because bytes_repeated_ >= 3.
        ASSERT(unemitted_bytes_ == 0);
        unemitted_bytes_valid_ = 1;
        unemitted_bytes_ = b;
      }
    }
    // Deflate doesn't work well with very large numbers of repetitions, so we
    // flush some of them here, but carry on in the previous mode.
    if (bytes_repeated_ == 260) output_repetitions(false);  // Will leave 3 repetitions.
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
  output_repetitions(true);
  output_unemitted();
  output_bits(0b0000000, 7);  // End of block.
  while (partial_bits_ > 0) {
    output_byte(partial_ & 0xff);
    partial_bits_ -= 8;
    partial_ >>= 8;
  }
}

void ZlibRle::output_unemitted() {
  while (unemitted_bytes_valid_ != 0) {
    unemitted_bytes_valid_--;
    int shift = unemitted_bytes_valid_ << 3;
    uint8 b = unemitted_bytes_ >> shift;
    literal(b);
  }
}

static const uint8 reversed_5[5] = {0, 0, 0b10000, 0b01000, 0b11000};

void ZlibRle::output_repetitions(bool as_much_as_possible) {
  // Deflate can only represent up to 257 length in a regular way.
  while (bytes_repeated_ > 0) {
    int r = Utils::min(257, bytes_repeated_);
    bytes_repeated_ -= r;
    while (bytes_repeated_ != 0 && bytes_repeated_ < 3 && r > 3) {
      // We prefer not to output a repetition of 1 or 2 at the end, since that is verbose.
      r--;
      bytes_repeated_++;
    }
    if (r <= 10) {
      output_bits(reverse_7(1 + r - 3), 7);  // Codes 1-8 inclusive indicate 3-10 repetitions.
    } else {
      r -= 3;  // Boundaries between encodings are now on bit boundaries: 8-15, 16-31, 32-63...
      int extra_bits_count = 29 - Utils::clz(r);  // For 8-15, clz returns 28, for 16-31 clz returns 27.
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
    ASSERT(mode_ != LITERAL);
    output_bits(reversed_5[mode_], 5);              // Distance depends on mode.
    if (!as_much_as_possible) break;
  }
  if (bytes_repeated_ == 0) {
    mode_ = LITERAL;
  }
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

#endif

}
