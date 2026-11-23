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
#include "utf_8_validator.h"
#include "objects.h"
#include "process.h"

#ifndef TOIT_MODEL
#error "TOIT_MODEL is not set"
#endif

namespace toit {

// Karl Malbrain's compact CRC-32. See "A compact CCITT crc16 and crc32 C implementation that balances processor
// cache usage against speed": http://www.geocities.com/malbrain/.
uint32 Utils::crc32(uint32 crc, const uint8* ptr, size_t length) {
  static const uint32 s_crc32[16] = {
      0x00000000, 0x1db71064, 0x3b6e20c8, 0x26d930ac, 0x76dc4190, 0x6b6b51f4, 0x4db26158, 0x5005713c,
      0xedb88320, 0xf00f9344, 0xd6d6a3e8, 0xcb61b38c, 0x9b64c2b0, 0x86d3d2d4, 0xa00ae278, 0xbdbdf21c
  };
  uint32 crcu32 = crc;
  crcu32 = ~crcu32;
  while (length--) {
    uint8 b = *ptr++;
    crcu32 = (crcu32 >> 4) ^ s_crc32[(crcu32 & 0xF) ^ (b & 0xF)];
    crcu32 = (crcu32 >> 4) ^ s_crc32[(crcu32 & 0xF) ^ (b >> 4)];
  }
  return ~crcu32;
}

bool Utils::is_valid_utf_8(const uint8* buffer, word length) {
  return utf8_is_valid(buffer, length);
}

// Assumes the input is valid UTF-8, for example from a Toit string.
// See also is_valid_utf_8.  Returns size in 16 bit code units.
// If output is null, does not write.  If output_length is too small,
// returns -1.
// Never reads past the input: a first byte that announces more bytes than
// there are, or is not a first byte, becomes the replacement character.
word Utils::utf_8_to_16(const uint8* input, word length, uint16* output, word output_length) {
  word size = 0;
  for (word i = 0; i < length; ) {
    uint8 prefix = input[i];
    word count = Utils::bytes_in_utf_8_sequence(prefix);
    int c;
    if (prefix > Utils::MAX_ASCII && (count < 2 || count > 4 || count > length - i)) {
      c = 0xfffd;
      count = 1;
    } else if (prefix > Utils::MAX_ASCII) {
      c = Utils::payload_from_prefix(prefix);
      for (word j = 1; j < count; j++) {
        c <<= Utils::UTF_8_BITS_PER_BYTE;
        c |= input[i + j] & Utils::UTF_8_MASK;
      }
    } else {
      c = prefix;
    }
    if (c < 0x10000) {
      if (output) {
        if (size >= output_length) return -1;
        output[size] = c;
      }
      size++;
    } else {
      // Surrogate pair.
      if (output) {
        c -= 0x10000;
        if (size + 1 >= output_length) return -1;
        output[size] = 0xd800 + (c >> 10);
        output[size + 1] = 0xdc00 + (c & 0x3ff);
      }
      size += 2;
    }
    i += count;
  }
  return size;
}

// Returns size in bytes.  Replaces invalid UTF-16 with 0xFFFD, the replacement
//   character.
// length is given in 16 bit UTF-16 code points.
// If output is null, does not write.
word Utils::utf_16_to_8(const uint16* input, word length, uint8* output, word output_length) {
  return utf_16le_to_8(reinterpret_cast<const uint8*>(input), length, output, output_length);
}

static uint16 read_utf16le_unit(const uint8* input, word index) {
  uword offset = static_cast<uword>(index) * sizeof(uint16);
  return input[offset] + (input[offset + 1] << 8);
}

word Utils::utf_16le_to_8(const uint8* input, word length, uint8* output, word output_length) {
  word size = 0;
  for (word i = 0; i < length; i++) {
    int c = read_utf16le_unit(input, i);
    if (Utils::MIN_SURROGATE <= c && c <= Utils::MAX_SURROGATE) {
      // Surrogate pairs.
      int decoded = 0xfffd;  // Substitute character for illegal sequences.
      if (i + 1 != length) {
        uint16 part2 = read_utf16le_unit(input, i + 1);
        if (0xd800 <= c && c <= 0xdbff && 0xdc00 <= part2 && part2 <= 0xdfff) {
          decoded = 0x10000 + ((c & 0x3ff) << 10) + (part2 & 0x3ff);
          i++;
        }
      }
      c = decoded;
    }
    if (c <= Utils::MAX_ASCII) {
      if (output) {
        if (size == output_length) return -1;
        output[size] = c;
      }
      size++;
    } else if (c <= Utils::MAX_TWO_BYTE_UNICODE) {
      if (output) {
        if (size + 1 >= output_length) return -1;
        output[size]     = 0xc0 + (c >> 6);
        output[size + 1] = Utils::UTF_8_PAYLOAD + (c & Utils::UTF_8_MASK);
      }
      size += 2;
    } else if (c <= Utils::MAX_THREE_BYTE_UNICODE) {
      if (output) {
        if (size + 2 >= output_length) return -1;
        output[size]     = 0xe0 + (c >> 12);
        output[size + 1] = Utils::UTF_8_PAYLOAD + ((c >> 6) & Utils::UTF_8_MASK);
        output[size + 2] = Utils::UTF_8_PAYLOAD + (c & Utils::UTF_8_MASK);
      }
      size += 3;
    } else {
      if (output) {
        if (size + 3 >= output_length) return -1;
        output[size]     = 0xf0 + (c >> 18);
        output[size + 1] = Utils::UTF_8_PAYLOAD + ((c >> 12) & Utils::UTF_8_MASK);
        output[size + 2] = Utils::UTF_8_PAYLOAD + ((c >> 6) & Utils::UTF_8_MASK);
        output[size + 3] = Utils::UTF_8_PAYLOAD + (c & Utils::UTF_8_MASK);
      }
      size += 4;
    }
  }
  return size;
}

bool Utils::utf_8_equals_utf_16(const uint8* input1, word length1, const uint16* input2, word length2) {
  // The UTF-16 encoding always has fewer code units than the UTF-8 encoding.
  if (length2 > length1) return false;

  // Zero length strings are equal.
  if (length1 == 0) return true;

  // Worst blow-up is 3x because all UTF-8 sequences are 1-4 bytes and the
  // 4-byte encodings correspond to two UTF-16 surrogates.  Broken UTF-16
  // surrogates are encoded as a 3-byte substitution (0xfffd).
  if (length1 > length2 * 3) return false;

  // Quick out for different first ASCII letter.
  if ((input1[0] <= MAX_ASCII || input2[0] <= MAX_ASCII) && input1[0] != input2[0]) return false;

  // Start with length comparison of the UTF-16 version.
  if (length2 != utf_8_to_16(input1, length1)) return false;

  // Now we know the UTF-16 versions are the same length, generate the UTF-16
  // version of the UTF-8 input, and compare them.
  static const word BUFFER_SIZE = 260;
  uint16 buffer[BUFFER_SIZE];
  uint16* wide_input1 = length2 < BUFFER_SIZE
      ? buffer
      : unvoid_cast<uint16*>(malloc(sizeof(uint16) * length2));
  utf_8_to_16(input1, length1, wide_input1, length2);
  bool match = memcmp(wide_input1, input2, length2 * sizeof(uint16)) == 0;
  if (wide_input1 != buffer) free(wide_input1);
  return match;
}

// For use on Windows.  Takes the old environment in the format returned by
// GetEnvironmentStringsW() and an array of key-value pairs.  Returns a new
// environment in the same format, which should be freed when done.  Assumes
// that allocations don't fail.
// The format is a long series of null-terminated wide strings, followed by a
// null, so a zero length string is not possible.  Each string contains an
// equals sign that separates the key from the value.  If there is no equals
// sign then the whole thing is taken to be the key.
uint16* Utils::create_new_environment(Process* process, uint16* previous_environment, Array* environment) {
  uint16* new_environment = null;
  word length_so_far;
  word new_environment_length = 0;
  // First run calculates the length of the result.  Second run actually writes
  // the result.
  for (int runs = 0; runs < 2; runs++) {
    length_so_far = 0;
    bool writing = runs != 0;
    for (uint16* p = previous_environment; *p; ) {
      word len = 0;
      word utf_16_key_length = -1;
      while (p[len] != 0) {
        if (utf_16_key_length == -1 && p[len] == '=') utf_16_key_length = len;
        len++;
      }
      if (utf_16_key_length == -1) utf_16_key_length = len;  // No '=' symbol found.
      word utf_16_key_value_length = len;
      bool in_new_environment = false;
      // Environment variable key  from p to p + utf_16_key_value_length.
      // Environment variable name from p to p + utf_16_key_length.
      for (word i = 0; i < environment->length(); i += 2) {
        Blob key;
        environment->at(i)->byte_content(process->program(), &key, STRINGS_ONLY);
        if (utf_8_equals_utf_16(key.address(), key.length(), p, utf_16_key_length)) {
          // Keys match, so we won't be taking this key-value pair from the old environment.
          in_new_environment = true;
          break;
        }
      }
      if (!in_new_environment) {
        if (writing) {
          memcpy(new_environment + length_so_far, p, (utf_16_key_value_length + 1) * sizeof(uint16));
        }
        length_so_far += utf_16_key_value_length + 1;  // Add the null terminator.
      }
      p += utf_16_key_value_length + 1;
    }
    // Now that we have inherited the environment variables that were not
    // mentioned in the new environment map, add the new variables.
    for (word i = 0; i < environment->length(); i += 2) {
      Blob key;
      if (environment->at(i + 1) != process->null_object()) {
        Blob key, value;
        environment->at(i    )->byte_content(process->program(), &key, STRINGS_ONLY);
        environment->at(i + 1)->byte_content(process->program(), &value, STRINGS_ONLY);
        uint16* dest = writing ? new_environment + length_so_far : null;
        word utf_16_key_length = utf_8_to_16(key.address(), key.length(), dest, new_environment_length - length_so_far);
        length_so_far += utf_16_key_length + 1;
        if (writing) {
          new_environment[length_so_far - 1] = '=';
          dest = new_environment + length_so_far;
        }
        word utf_16_value_length = utf_8_to_16(value.address(), value.length(), dest, new_environment_length - length_so_far);
        length_so_far += utf_16_value_length + 1;
        if (writing) {
          new_environment[length_so_far - 1] = 0;
        }
      }
    }
    length_so_far++;   // Ends with a double null terminator.
    if (writing) {
      new_environment[length_so_far - 1] = 0;
    } else {
      new_environment = unvoid_cast<uint16*>(malloc(sizeof(uint16) * length_so_far));
      new_environment_length = length_so_far;
    }
  }
  return new_environment;
}


#define L0 0, 1, 1, 2, 1, 2, 2, 3,
#define L1 1, 2, 2, 3, 2, 3, 3, 4,
#define L2 2, 3, 3, 4, 3, 4, 4, 5,
#define L3 3, 4, 4, 5, 4, 5, 5, 6,
#define L4 4, 5, 5, 6, 5, 6, 6, 7,
#define L5 5, 6, 6, 7, 6, 7, 7, 8,

const uint8 Utils::popcount_table[256] = {
  L0 L1 L1 L2 L1 L2 L2 L3
  L1 L2 L2 L3 L2 L3 L3 L4
  L1 L2 L2 L3 L2 L3 L3 L4
  L2 L3 L3 L4 L3 L4 L4 L5
};

const char* vm_git_version() { return VM_GIT_VERSION; }
const char* vm_git_info() { return VM_GIT_INFO; }
const char* vm_sdk_model() { return TOIT_MODEL; }

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

static const char base64url_output_table[12] = {
    26, 'Z' + 1,
    26, 'z' + 1,
    10, '9' + 1,
    1, '-' + 1,
    1, '_' + 1,
    1, '=' + 1
};

// Base-64 encode a number between 0 and 64 to the characters defined by p.
static uint8 write_64(int bits, const char* p) {
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
  // Unsigned, as the bits that have been output are shifted out at the top.
  uword r = rest;
  const char* table = url_mode ? base64url_output_table : base64_output_table;
  word c = bit_count;
  for (word i = 0; i < size; i++) {
    int byte = data[i];
    r = (r << 8) | byte;
    c += 8;
    while (c >= 6) {
      f(write_64((r >> (c - 6)) & 0x3f, table));
      c -= 6;
    }
  }
  rest = r;
  bit_count = c;
}

void Base64Encoder::finish(const std::function<void (uint8 out_byte)>& f) {
  // Shift remaining bits to high end of 6-bit field.
  word r = (rest << (6 - bit_count)) & 0x3f;
  if (url_mode) {
    if (bit_count != 0) {
      f(write_64(r, base64url_output_table));
    }
    return;
  }
  word c = bit_count;
  // Turn 0, 2 or 4 remaining bits into into 0, 3 or 2 bytes to output.
  int iterations = "\0.\3.\2"[c];
  for (int i = iterations; i > 0; i--) {
    f(write_64(r, base64_output_table));
    r = 64;  // Pad with "=".
  }
}

void iram_safe_char_memcpy(char* dst, const char* src, size_t bytes) {
  ASSERT((bytes & 3) == 0);
  ASSERT(((uintptr_t)src & 3) == 0);
#if defined(CONFIG_IDF_TARGET_ESP32) || defined(CONFIG_IDF_TARGET_ESP32S3)
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
#elif (!defined(TOIT_ESP32)) || \
      defined(CONFIG_IDF_TARGET_ESP32C3) || \
      defined(CONFIG_IDF_TARGET_ESP32C6) || \
      defined(CONFIG_IDF_TARGET_ESP32P4) || \
      defined(CONFIG_IDF_TARGET_ESP32S2)
  memcpy(dst, src, bytes);
#else
  #error "Unknown target"
#endif
}

}
