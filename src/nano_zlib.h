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

#pragma once

#include "resource.h"
#include "tags.h"
#include "utils.h"

namespace toit {

class Adler32 : public SimpleResource {
 public:
  TAG(Adler32);
  Adler32(SimpleResourceGroup* group) : SimpleResource(group), s1(1), s2(0), count(0) {}

  inline void add(const uint8* contents, intptr_t extra) {
    for (intptr_t i = 0; i < extra; i++) {
      uint8 b = contents[i];
      s1 += b;
      if (s1 >= 65521) s1 -= 65521;
      s2 += s1;
      if (s2 >= 65521) s2 -= 65521;
    }
    count += extra;
  }

  // For using Adler-32 as a rolling checksum, we need to remove
  // bytes from the start of the data stream, ie calculate what
  // the checksum would have been if those initial bytes had not
  // been present.
  inline void unadd(const uint8* contents, intptr_t extra) {
    for (intptr_t i = 0; i < extra; i++) {
      uint8 b = contents[i];
      s1 -= b;
      if (s1 < 0 ) s1 += 65521;
      // We need to subtract count * b from s2, since it has been
      // added count times to s2.
      int32 mod_count = count;
      if (mod_count >= 65521) mod_count %= 65521;
      int32 subtract = ((mod_count * b) + 1) % 65521;
      s2 -= subtract;
      if (s2 < 0) s2 += 65521;
      count--;
    }
  }

  inline void get(uint8* hash) {
    hash[0] = s2 >> 8;
    hash[1] = s2;
    hash[2] = s1 >> 8;
    hash[3] = s1;
  }

 private:
  int32 s1;
  int32 s2;
  int32 count;
};

class ZlibRle : public SimpleResource {
 public:
  TAG(ZlibRle);

  ZlibRle(SimpleResourceGroup* group) : SimpleResource(group) {}

  void set_output_buffer(uint8* output, word position, word limit);
  word get_output_index();
  // Returns the number of bytes read.  Use get_output_index to find the
  // number of bytes written.
  word add(const uint8* contents, intptr_t extra);
  void finish();

 protected:
  void output_byte(uint8);

 private:
  void literal(uint8 byte);
  void output_repetitions(bool as_much_as_possible = true);
  void output_bits(uint32 bits, int bit_count);
  void output_unemitted();

  // The integer values are used in various places in nano_zlib.cc.
  enum Mode {
    LITERAL,   // We have not recognized any pattern in the bytes being compressed.
    REP1 = 1,  // A run of identical bytes has been recognized.
    REP2 = 2,  // A pattern of the form abababab has been recognized.
    REP3 = 3,  // A pattern of the form abcabcabc has been recognized.
    REP4 = 4   // A pattern of the form abcdabcd has been recognized.
  };

  uint32 partial_ = 0;
  int partial_bits_ = 0;
  bool initialized_ = false;

  uint8* output_buffer_ = null;
  word output_index_ = 0;
  word output_limit_ = 0;

  Mode mode_ = LITERAL;
  uint32 last_bytes_ = 0;  // Most recent byte is least significant.
  uint32 last_bytes_valid_ = 0;
  uint32 unemitted_bytes_ = 0;  // Chronologically last byte is least significant.
  uint32 unemitted_bytes_valid_ = 0;
  int bytes_repeated_ = 0;

};

}
