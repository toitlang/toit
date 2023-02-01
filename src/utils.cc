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
#include "objects.h"
#include "process.h"

#ifndef TOIT_MODEL
#error "TOIT_MODEL is not set"
#endif

namespace toit {

#ifdef BUILD_64

/**
9 states that handle all UTF-8 states.
We use 6 bits per state, so in all we need 54 bits and it fits in a 64 bit
unsigned int.  (The state machine is better explained in the 32 bit version
below.  Search for "Part two of the verification".)
*/
static const uint64 UTF_MASK              = 0x3f;
static const uint64 UTF_BASE              = 0;   // Initial state, also the one we want to end in.
static const uint64 UTF_LAST              = 6;   // Expect the last byte of a multi-byte sequence.
static const uint64 UTF_PENULTIMATE       = 12;  // Expect the 2nd last of a multi-byte sequence.
static const uint64 UTF_ANTEPENULTIMATE   = 18;  // Expect the 3rd last of a multi-byte sequence.
static const uint64 UTF_OVERLONG_4_CHECK  = 24;  // Look out for overlong 4-byte sequences.
static const uint64 UTF_RANGE_CHECK       = 30;  // Look out for sequences that are above 0x10ffff.
static const uint64 UTF_OVERLONG_3_CHECK  = 36;  // Look out for overlong 3-byte sequences.
static const uint64 UTF_SURROGATE_CHECK   = 42;  // Look out for encodings of surrogates.
static const uint64 UTF_ERR               = 48;  // Sticky error state.

// Use this for UTF-8 bytes that can only arrive in the BASE state.
static const uint64 UTF_SEQUENCE_START = 0x0030c30c30c30c00ll;

static const uint64 UTF_ASC     = UTF_SEQUENCE_START | UTF_BASE;  // Stay in the base state.
static const uint64 UTF_cdx     = UTF_SEQUENCE_START | UTF_LAST;  // 0xcx and 0xdx start a two-byte sequence.
static const uint64 UTF_ex      = UTF_SEQUENCE_START | UTF_PENULTIMATE;  // 0xex starts a 3-byte sequence.
static const uint64 UTF_fx      = UTF_SEQUENCE_START | UTF_ANTEPENULTIMATE;  // 0xfx starts a 4-byte sequence.
static const uint64 UTF_ILL     = UTF_SEQUENCE_START | UTF_ERR;   // All states go to ERR.

// For a continuation byte (starting with 10 bits) most states move to the next
// of a multi-byte sequence.
// from: ERR RANGE    OVERLONG ANTEPENU PENULTIM LAST   BASE
//   to: ERR PENULTIM PENULTIM PENULTIM LAST     BASE   ERR
static const uint64 UTF_10 =
    (UTF_ERR << UTF_ERR) |
    (UTF_PENULTIMATE << UTF_ANTEPENULTIMATE) |
    (UTF_LAST << UTF_PENULTIMATE) |
    (UTF_BASE << UTF_LAST) |
    UTF_ERR;

// 0x80-0x8f.
static const uint64 UTF_8x  = UTF_10
    | (UTF_ERR << UTF_OVERLONG_3_CHECK)          // 0x8x not OK after 0xe0.
    | (UTF_ERR << UTF_OVERLONG_4_CHECK)          // 0x8x not OK after 0xf0.
    | (UTF_PENULTIMATE << UTF_RANGE_CHECK)       // 0x8x OK after 0xf4, within 0x10ffff limit.
    | (UTF_LAST << UTF_SURROGATE_CHECK);         // 0x8x OK after 0xed, not in surrogate range.
// 0x90-0x9f.
static const uint64 UTF_9x  = UTF_10
    | (UTF_ERR << UTF_OVERLONG_3_CHECK)          // 0x9x not OK after 0xe0.
    | (UTF_PENULTIMATE << UTF_OVERLONG_4_CHECK)  // 0x9x OK after 0xf0.
    | (UTF_ERR << UTF_RANGE_CHECK)               // 0x9x not OK after 0xf4, outside 0x10ffff limit.
    | (UTF_LAST << UTF_SURROGATE_CHECK);         // 0x9x OK after 0xed, not in surrogate range.
// 0xa0-0xbf.
static const uint64 UTF_abx  = UTF_10
    | (UTF_LAST << UTF_OVERLONG_3_CHECK)         // 0x[ab]x OK after 0xe0.
    | (UTF_PENULTIMATE << UTF_OVERLONG_4_CHECK)  // 0x[ab]x OK after 0xf0.
    | (UTF_ERR << UTF_RANGE_CHECK)               // 0x[ab]x not OK after 0xf4, outside 0x10ffff limit.
    | (UTF_ERR << UTF_SURROGATE_CHECK);          // 0x[ab]x not OK after 0xed, in surrogate range.

static uint64 UTF_8_STATE_TABLE[256] = {
  // 0x00-0x7f, the ASCII range.
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  // 0x80-0x8f - not allowed after 0xe0 or 0xf0 (overlong).
  UTF_8x, UTF_8x, UTF_8x, UTF_8x, UTF_8x, UTF_8x, UTF_8x, UTF_8x,
  UTF_8x, UTF_8x, UTF_8x, UTF_8x, UTF_8x, UTF_8x, UTF_8x, UTF_8x,
  // 0x90-0x9f - not allowed after 0xe0 or 0xf4 (overlong or out of range).
  UTF_9x, UTF_9x, UTF_9x, UTF_9x, UTF_9x, UTF_9x, UTF_9x, UTF_9x,
  UTF_9x, UTF_9x, UTF_9x, UTF_9x, UTF_9x, UTF_9x, UTF_9x, UTF_9x,
  // 0xa0-0xbf - not allowed after 0xf4 or 0xed (out of range or surrogate).
  UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx,
  UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx,
  UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx,
  UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx, UTF_abx,
  // 0xc0-0xc1 - illegal in all states.
  UTF_ILL, UTF_ILL,
  // 0xc2-0xdf - start of a 2-byte sequence.
  UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx,
  UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx,
  UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx,
  UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx, UTF_cdx,
  // 0xe0 - move to state that checks for overlong 3-byte sequences.
  UTF_SEQUENCE_START | UTF_OVERLONG_3_CHECK,
  // 0xe1-0xec - start of a 3-byte sequence.
  UTF_ex, UTF_ex, UTF_ex, UTF_ex, UTF_ex, UTF_ex, UTF_ex,
  UTF_ex, UTF_ex, UTF_ex, UTF_ex, UTF_ex,
  // 0xed - move to state that checks for surrogate characters.
  UTF_SEQUENCE_START | UTF_SURROGATE_CHECK,
  // 0xee-0xef - start of a 3-byte sequence.
  UTF_ex, UTF_ex,
  // 0xf0 - move to state that checks for overlong 4-byte sequences.
  UTF_SEQUENCE_START | UTF_OVERLONG_4_CHECK,
  // 0xf1-0xf3 - Regular 4-byte sequences.
  UTF_fx, UTF_fx, UTF_fx,
  // 0xf4 - move to state that checks for Unicode values past 0x10ffff.
  UTF_SEQUENCE_START | UTF_RANGE_CHECK,
  // 0xf5-0xff - illegal in all states.
  UTF_ILL, UTF_ILL, UTF_ILL,
  UTF_ILL, UTF_ILL, UTF_ILL, UTF_ILL, UTF_ILL, UTF_ILL, UTF_ILL, UTF_ILL,
};

static const uint64 HIGH_BIT_OF_EACH_BYTE = 0x8080808080808080LLU;

#else

// The table used for 64 bit is a bit big for use on small targets.  It's 2k
// large.  Also, 32 bit platforms are not so fast at shifting 64 bit numbers.
// Instead we have an approach with two smaller tables (512 bytes and 64
// bytes).  The large table takes care of the correct order of the high nibbles
// of UTF-8 bytes, ie whether the byte stream is organized in a whole number of
// code points.  The smaller table checks for overlong encodings, surrogates
// and code points that are too high.  It also detects completely banned
// bytes.

// We will use 16 bits of state where a 1 at position n indicates that the
// next input byte may have a value from 0xn0 to 0xnf.

// After an ASCII byte we allow any byte that starts a UTF-8 sequence, ie
// 0x00-0x7f or 0xc0-0xff.
static const uint16 START = 0xf0ff;

// After a byte starting with 0b10... we allow any byte.
static const uint16 ANY = 0xffff;

// After a byte starting with 0b11... we normally allow any byte in the
// 0x80-0xbf range (those starting 0b10...).
static const uint16 CONT = 0x0f00;

// Table used to check for overlong encodings, characters above 0x10ffff, and
// surrogate encodings.  Use a byte as index into this table to determine which
// high nibbles are allowed in the next byte.
static uint16 MALFORMED_TABLE[256] = {
  // After an ASCII character we allow 0x00-0x7f or 0xc0-0xf0.
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  START, START, START, START, START, START, START, START,
  // After 0x80-0xbf we can have anything.
  ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY,
  ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY,
  ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY,
  ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY,
  // Nothing is allowed after 0xc0-0xc1 (overlong encoding).
  0, 0,
  // After 0xc2-0xdf we allow any in the range 0x80-0xbf.
  CONT, CONT, CONT, CONT, CONT, CONT,
  CONT, CONT, CONT, CONT, CONT, CONT, CONT, CONT,
  CONT, CONT, CONT, CONT, CONT, CONT, CONT, CONT,
  CONT, CONT, CONT, CONT, CONT, CONT, CONT, CONT,
  // After 0xe0 we allow 0xa0-0xbf (others are overlong).
  (1 << 0xa) | (1 << 0xb),
  // After 0xe1-0xec we allow any in the range 0x80-0xbf.
  CONT, CONT, CONT, CONT, CONT, CONT, CONT, CONT,
  CONT, CONT, CONT, CONT,
  // After 0xed we allow 0x80-0x90 (others are surrogates).
  (1 << 0x8) | (1 << 0x9),
  // After 0xee-0xef we allow any in the range 0x80-0xbf.
  CONT, CONT,
  // After 0xf0 we allow 0x90-0xbf (0x80-0x8f are overlong).
  (1 << 0x9) | (1 << 0xa) | (1 << 0xb),
  // After 0xf1-0xf3 we allow any in the range 0x80-0xbf.
  CONT, CONT, CONT,
  // After 0xf4 we allow 0x80-0x8f.  Others correspond to code points above
  // 0x10ffff.
  1 << 0x8,
  // Nothing is allowed after 0xf5-0xff.
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

/*
Part two of the verification uses one of 5 states to index into
a 32 bit word to find the next state.

Use 5 bits per state for a 25 bit int:

On each iteration we use a 25 bit word to find the next state.
The 25 bit word is determined by the high nibble of the previous
input byte.

Bits 0-4: next state after UTF_BASE.
Bits 5-9: next state after UTF_LAST.
Bits 10-14: next state after UTF_PENULTIMATE.
Bits 15-19: next state after UTF_ANTEPENULTIMATE.
Bits 20-24: Next state after UTF_ERR.
*/
static const uint32 UTF_MASK            = 0x1f;
static const uint32 UTF_BASE            = 0;   // Initial state, also the one we want to end in.
static const uint32 UTF_LAST            = 5;   // Expect the last byte of a multi-byte sequence.
static const uint32 UTF_PENULTIMATE     = 10;  // Expect the 2nd last of a multi-byte sequence.
static const uint32 UTF_ANTEPENULTIMATE = 15;  // Expect the 3rd last of a multi-byte sequence.
static const uint32 UTF_ERR             = 20;  // Sticky error state.

// Use this for UTF-8 bytes that can only arrive in the BASE state.
static const uint32 UTF_SEQUENCE_START =
    (UTF_ERR << UTF_LAST) |
    (UTF_ERR << UTF_PENULTIMATE) |
    (UTF_ERR << UTF_ANTEPENULTIMATE) |
    (UTF_ERR << UTF_ERR);

static const uint32 UTF_ASC = UTF_SEQUENCE_START | UTF_BASE;  // Stay in the base state.

// If we are in base state, error.  Otherwise go down one state.
static const uint32 UTF_CONT =
    UTF_ERR |
    (UTF_BASE << UTF_LAST) |
    (UTF_LAST << UTF_PENULTIMATE) |
    (UTF_PENULTIMATE << UTF_ANTEPENULTIMATE) |
    (UTF_ERR << UTF_ERR);

static uint32 UTF_8_STATE_TABLE_32[16] = {
  // 00-7f  Go to error unless we are already in BASE mode.
  UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC, UTF_ASC,
  // 0x80-0xbf  Count down the state whenever a continuation byte like this arrives.
  UTF_CONT,
  UTF_CONT,
  UTF_CONT,
  UTF_CONT,
  // 0xc0-0xdf  Expect one continuation byte.
  UTF_SEQUENCE_START | UTF_LAST,
  UTF_SEQUENCE_START | UTF_LAST,
  // 0xe0-0xef  Expect two continuation bytes.
  UTF_SEQUENCE_START | UTF_PENULTIMATE,
  // 0xf0-0xff  Expect three continuation bytes.
  UTF_SEQUENCE_START | UTF_ANTEPENULTIMATE
};

static const uint32 HIGH_BIT_OF_EACH_BYTE = 0x80808080;

#endif

bool Utils::is_valid_utf_8(const uint8* buffer, int length) {
  // Align.
  while (length != 0 && !is_aligned(buffer, WORD_SIZE) && (buffer[0] & 0xff) <= MAX_ASCII) {
    length--;
    buffer++;
  }
  if (is_aligned(buffer, WORD_SIZE)) {
    // Word-at-a-time.
    while (length >= WORD_SIZE && (*reinterpret_cast<const uword*>(buffer) & HIGH_BIT_OF_EACH_BYTE) == 0) {
      buffer += WORD_SIZE;
      length -= WORD_SIZE;
    }
  }
#ifdef BUILD_64
  // Thanks to Per Vognsen.  Explanation at
  // https://gist.github.com/pervognsen/218ea17743e1442e59bb60d29b1aa725
  uint64 state = UTF_BASE;
  for (int i = 0; i < length; i++) {
    unsigned char c = buffer[i];
    state = UTF_8_STATE_TABLE[c] >> (state & UTF_MASK);  // The '&' is optimized out.
  }
  return (state & UTF_MASK) == UTF_BASE;
#else
  int32 state = UTF_BASE;
  int allowed_nibbles = START;
  for (int i = 0; i < length; i++) {
    unsigned char c = buffer[i];
    int high_nibble = c >> 4;
    if ((allowed_nibbles & (1 << high_nibble)) == 0) return false;
    state = UTF_8_STATE_TABLE_32[high_nibble] >> (state & UTF_MASK);  // The '&' is optimized out.
    allowed_nibbles = MALFORMED_TABLE[c];
  }
  return (state & UTF_MASK) == UTF_BASE;
#endif
}

// Assumes the input is valid UTF-8, for example from a Toit string.
// See also is_valid_utf_8.  Returns size in 16 bit code units.
// If output is null, does not write.  If output_length is too small,
// returns -1.
word Utils::utf_8_to_16(const uint8* input, word length, uint16* output, word output_length) {
  word size = 0;
  for (word i = 0; i < length; ) {
    uint8 prefix = input[i];
    word count = Utils::bytes_in_utf_8_sequence(prefix);
    int c;
    if (prefix > Utils::MAX_ASCII) {
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
  word size = 0;
  for (word i = 0; i < length; i++) {
    int c = input[i];
    if (Utils::MIN_SURROGATE <= c && c <= Utils::MAX_SURROGATE) {
      // Surrogate pairs.
      int decoded = 0xfffd;  // Substitute character for illegal sequences.
      if (i + 1 != length) {
        uint16 part2 = input[i + 1];
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
      for (int i = 0; i < environment->length(); i += 2) {
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
    for (int i = 0; i < environment->length(); i += 2) {
      Blob key;
      if (environment->at(i + 1) != process->program()->null_object()) {
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
  word r = rest;
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
#if defined(TOIT_FREERTOS) && !defined(CONFIG_IDF_TARGET_ESP32C3) && !defined(CONFIG_IDF_TARGET_ESP32S2)
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
