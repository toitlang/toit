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

#include "utils.h"

#ifndef TOIT_MODEL
#error "TOIT_MODEL is not set"
#endif

namespace toit {

#ifdef BUILD_64
static uint64_t UTF_8_STATE_TABLE[] = {
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030c30c30c30c00ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030330306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c306c06030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c0c330186030ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c06ll,
  0x0030c30c30c30c12ll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c18ll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c0cll,
  0x0030c30c30c30c24ll,
  0x0030c30c30c30c1ell,
  0x0030c30c30c30c1ell,
  0x0030c30c30c30c1ell,
  0x0030c30c30c30c2all,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
  0x0030c30c30c30c30ll,
};
#endif

bool Utils::is_valid_utf_8(const uint8* buffer, int length) {
  // Align.
  while (length != 0 && !is_aligned(buffer, 4) && (buffer[0] & 0xff) <= MAX_ASCII) {
    length--;
    buffer++;
  }
  if (is_aligned(buffer, 4)) {
    // Word-at-a-time.
    while (length >= 4 && (*reinterpret_cast<const uint32_t*>(buffer) & 0x80808080) == 0) {
      buffer += 4;
      length -= 4;
    }
  }
#ifdef BUILD_64
  // Thanks to Per Vognsen.  Explanation at
  // https://gist.github.com/pervognsen/218ea17743e1442e59bb60d29b1aa725
  uint64_t state = 0;
  for (int i = 0; i < length; i++) {
    unsigned char c = buffer[i];
    state = UTF_8_STATE_TABLE[c] >> (state & 0x3f);
  }
  return (state & 0x3f) == 0;
#else
  for (int i = 0; i < length; i++) {
    int c = buffer[i] & 0xff;
    if (c <= MAX_ASCII) continue;
    if (!is_utf_8_prefix(c)) return false;  // Unexpected continuation byte.
    // Count leading ones to determine number of bytes in multi-byte encoding.
    int n_byte_sequence = bytes_in_utf_8_sequence(c);
    if (n_byte_sequence > 4) return false;  // No 5-byte-sequences or above allowed.
    if (i + n_byte_sequence > length) return false;  // Ends with incomplete character.
    c = payload_from_prefix(c);
    for (int j = 1; j < n_byte_sequence; j++) {
      c <<= UTF_8_BITS_PER_BYTE;
      uint8 b = buffer[i + j];
      if ((b ^ 0x80) > 0x3f) return false;  // Only allow bytes 0x80-0xbf.
      c |= b & UTF_8_MASK;
    }
    // Surrogate pairs should be encoded as one 4-byte UTF-8 sequence.
    if (MIN_SURROGATE <= c && c <= MAX_SURROGATE) return false;
    // No overlong sequences.
    if (c <= MAX_UTF_8_VALUES[n_byte_sequence - 2]) return false;
    if (c > MAX_UNICODE) return false;
    i += n_byte_sequence - 1;
  }
  return true;
#endif
}

const char* vm_git_version() { return VM_GIT_VERSION; }
const char* vm_git_info() { return VM_GIT_INFO; }
const char* vm_sdk_model() { return TOIT_MODEL; }

void dont_optimize_away_these_allocations(void** blocks) {}

const uint8 Utils::REVERSE_NIBBLE[16] = {
    0b0000,
    0b1000,
    0b0100,
    0b1100,
    0b0010,
    0b1010,
    0b0110,
    0b1110,
    0b0001,
    0b1001,
    0b0101,
    0b1101,
    0b0011,
    0b1011,
    0b0111,
    0b1111};

static const char base64_output_table[12] = {
    26, 'Z' + 1,
    26, 'z' + 1,
    10, '9' + 1,
    1, '+' + 1,
    1, '/' + 1,
    1, '=' + 1
};

// Base-64 encode a number between 0 and 64 to the characters A-Za-z0-9+/=
static uint8 write_64(int bits) {
  const char* p = base64_output_table;
  while (true) {
    bits -= *p;
    p += 2;
    if (bits < 0) {
      return p[-1] + bits;
    }
  }
  UNREACHABLE();
}

void Base64Encoder::encode(const uint8* data, word size, const std::function<void (uint8 out_byte)>& f) {
  // Output a buffer in base64 encoding, outputting 3 input bytes as 4 output
  // bytes.
  word r = rest;
  word c = bit_count;
  for (word i = 0; i < size; i++) {
    int byte = data[i];
    r = (r << 8) | byte;
    c += 8;
    while (c >= 6) {
      f(write_64((r >> (c - 6)) & 0x3f));
      c -= 6;
    }
  }
  rest = r;
  bit_count = c;
}

void Base64Encoder::finish(const std::function<void (uint8 out_byte)>& f) {
  // Shift remaining bits to high end of 6-bit field.
  word c = bit_count;
  word r = (rest << (6 - c)) & 0x3f;
  // Turn 0, 2 or 4 into 0, 3 or 2.
  int iterations = "\0.\3.\2"[c];
  for (int i = iterations; i > 0; i--) {
    f(write_64(r));
    r = 64;  // Pad with "=".
  }
}

void iram_safe_char_memcpy(char* dst, const char* src, size_t bytes) {
  ASSERT((bytes & 3) == 0);
  ASSERT(((uintptr_t)src & 3) == 0);
#ifdef TOIT_FREERTOS
  uint32_t tmp;
  __asm__ __volatile__(
    "srai %3, %3, 2   \n"  // Divide bytes by 4.
    "loopnez %3, 1f   \n"  // Set up loop, branch over if bytes is zero.
    "l32i.n %0, %2, 0 \n"  // Load from src.
    "addi.n %2, %2, 4 \n"  // src++
    "s32i.n %0, %1, 0 \n"  // Store to dst.
    "addi.n %1, %1, 4 \n"  // dst++
    "1:               \n"  // Implicit backwards edge of loop.
    // Output operands.
    : "=&r" (tmp)
    // Input operands.
    : "r" (dst), "r" (src), "r" (bytes)
    // Clobbers.
    : );
#else
  memcpy(dst, src, bytes);
#endif
}

}
