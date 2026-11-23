// Copyright (C) 2018 Toitware ApS.
// Copyright (C) 2026 Toit contributors.
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

#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
namespace toit {
#else
#include <stdbool.h>
#endif

#if UINTPTR_MAX == UINT64_MAX

/**
9 states that handle all UTF-8 states.
We use 6 bits per state, so in all we need 54 bits and it fits in a 64 bit
unsigned int.  (The state machine is better explained in the 32 bit version
below.  Search for "Part two of the verification".)
*/
static const uint64_t UTF_MASK              = 0x3f;
static const uint64_t UTF_BASE              = 0;   // Initial state, also the one we want to end in.
static const uint64_t UTF_LAST              = 6;   // Expect the last byte of a multi-byte sequence.
static const uint64_t UTF_PENULTIMATE       = 12;  // Expect the 2nd last of a multi-byte sequence.
static const uint64_t UTF_ANTEPENULTIMATE   = 18;  // Expect the 3rd last of a multi-byte sequence.
static const uint64_t UTF_OVERLONG_4_CHECK  = 24;  // Look out for overlong 4-byte sequences.
static const uint64_t UTF_RANGE_CHECK       = 30;  // Look out for sequences that are above 0x10ffff.
static const uint64_t UTF_OVERLONG_3_CHECK  = 36;  // Look out for overlong 3-byte sequences.
static const uint64_t UTF_SURROGATE_CHECK   = 42;  // Look out for encodings of surrogates.
static const uint64_t UTF_ERR               = 48;  // Sticky error state.

// Use this for UTF-8 bytes that can only arrive in the BASE state.
static const uint64_t UTF_SEQUENCE_START = 0x0030c30c30c30c00ll;

static const uint64_t UTF_ASC     = UTF_SEQUENCE_START | UTF_BASE;  // Stay in the base state.
static const uint64_t UTF_cdx     = UTF_SEQUENCE_START | UTF_LAST;  // 0xcx and 0xdx start a two-byte sequence.
static const uint64_t UTF_ex      = UTF_SEQUENCE_START | UTF_PENULTIMATE;  // 0xex starts a 3-byte sequence.
static const uint64_t UTF_fx      = UTF_SEQUENCE_START | UTF_ANTEPENULTIMATE;  // 0xfx starts a 4-byte sequence.
static const uint64_t UTF_ILL     = UTF_SEQUENCE_START | UTF_ERR;   // All states go to ERR.

// For a continuation byte (starting with 10 bits) most states move to the next
// of a multi-byte sequence.
// from: ERR RANGE    OVERLONG ANTEPENU PENULTIM LAST   BASE
//   to: ERR PENULTIM PENULTIM PENULTIM LAST     BASE   ERR
static const uint64_t UTF_10 =
    (UTF_ERR << UTF_ERR) |
    (UTF_PENULTIMATE << UTF_ANTEPENULTIMATE) |
    (UTF_LAST << UTF_PENULTIMATE) |
    (UTF_BASE << UTF_LAST) |
    UTF_ERR;

// 0x80-0x8f.
static const uint64_t UTF_8x  = UTF_10
    | (UTF_ERR << UTF_OVERLONG_3_CHECK)          // 0x8x not OK after 0xe0.
    | (UTF_ERR << UTF_OVERLONG_4_CHECK)          // 0x8x not OK after 0xf0.
    | (UTF_PENULTIMATE << UTF_RANGE_CHECK)       // 0x8x OK after 0xf4, within 0x10ffff limit.
    | (UTF_LAST << UTF_SURROGATE_CHECK);         // 0x8x OK after 0xed, not in surrogate range.
// 0x90-0x9f.
static const uint64_t UTF_9x  = UTF_10
    | (UTF_ERR << UTF_OVERLONG_3_CHECK)          // 0x9x not OK after 0xe0.
    | (UTF_PENULTIMATE << UTF_OVERLONG_4_CHECK)  // 0x9x OK after 0xf0.
    | (UTF_ERR << UTF_RANGE_CHECK)               // 0x9x not OK after 0xf4, outside 0x10ffff limit.
    | (UTF_LAST << UTF_SURROGATE_CHECK);         // 0x9x OK after 0xed, not in surrogate range.
// 0xa0-0xbf.
static const uint64_t UTF_abx  = UTF_10
    | (UTF_LAST << UTF_OVERLONG_3_CHECK)         // 0x[ab]x OK after 0xe0.
    | (UTF_PENULTIMATE << UTF_OVERLONG_4_CHECK)  // 0x[ab]x OK after 0xf0.
    | (UTF_ERR << UTF_RANGE_CHECK)               // 0x[ab]x not OK after 0xf4, outside 0x10ffff limit.
    | (UTF_ERR << UTF_SURROGATE_CHECK);          // 0x[ab]x not OK after 0xed, in surrogate range.

static const uint64_t UTF_8_STATE_TABLE[256] = {
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

static const uint64_t HIGH_BIT_OF_EACH_BYTE = 0x8080808080808080LLU;

#elif UINTPTR_MAX == UINT32_MAX

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
static const uint16_t START = 0xf0ff;

// After a byte starting with 0b10... we allow any byte.
static const uint16_t ANY = 0xffff;

// After a byte starting with 0b11... we normally allow any byte in the
// 0x80-0xbf range (those starting 0b10...).
static const uint16_t CONT = 0x0f00;

// Table used to check for overlong encodings, characters above 0x10ffff, and
// surrogate encodings.  Use a byte as index into this table to determine which
// high nibbles are allowed in the next byte.
static const uint16_t MALFORMED_TABLE[256] = {
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
The 25 bit intptr_t is determined by the high nibble of the previous
input byte.

Bits 0-4: next state after UTF_BASE.
Bits 5-9: next state after UTF_LAST.
Bits 10-14: next state after UTF_PENULTIMATE.
Bits 15-19: next state after UTF_ANTEPENULTIMATE.
Bits 20-24: Next state after UTF_ERR.
*/
static const uint32_t UTF_MASK            = 0x1f;
static const uint32_t UTF_BASE            = 0;   // Initial state, also the one we want to end in.
static const uint32_t UTF_LAST            = 5;   // Expect the last byte of a multi-byte sequence.
static const uint32_t UTF_PENULTIMATE     = 10;  // Expect the 2nd last of a multi-byte sequence.
static const uint32_t UTF_ANTEPENULTIMATE = 15;  // Expect the 3rd last of a multi-byte sequence.
static const uint32_t UTF_ERR             = 20;  // Sticky error state.

// Use this for UTF-8 bytes that can only arrive in the BASE state.
static const uint32_t UTF_SEQUENCE_START =
    (UTF_ERR << UTF_LAST) |
    (UTF_ERR << UTF_PENULTIMATE) |
    (UTF_ERR << UTF_ANTEPENULTIMATE) |
    (UTF_ERR << UTF_ERR);

static const uint32_t UTF_ASC = UTF_SEQUENCE_START | UTF_BASE;  // Stay in the base state.

// If we are in base state, error.  Otherwise go down one state.
static const uint32_t UTF_CONT =
    UTF_ERR |
    (UTF_BASE << UTF_LAST) |
    (UTF_LAST << UTF_PENULTIMATE) |
    (UTF_PENULTIMATE << UTF_ANTEPENULTIMATE) |
    (UTF_ERR << UTF_ERR);

static const uint32_t UTF_8_STATE_TABLE_32[16] = {
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

static const uint32_t HIGH_BIT_OF_EACH_BYTE = 0x80808080;
#else
#error Unsupported word size
#endif

/*@ requires 0 <= length;
    requires \valid_read(buffer + (0 .. length - 1));
    assigns \nothing;
*/
static inline bool utf8_is_valid(const uint8_t* buffer, intptr_t length) {
  const intptr_t word_size = sizeof(uintptr_t);
  // Align.
  /*@ loop invariant 0 <= length <= \at(length,Pre);
      loop invariant buffer == \at(buffer,Pre) + (\at(length,Pre) - length);
      loop assigns buffer, length;
      loop variant length;
  */
  while (length != 0 && ((uintptr_t)buffer & (sizeof(uintptr_t) - 1)) != 0 && buffer[0] <= 0x7f) {
    length--;
    buffer++;
  }
  if (((uintptr_t)buffer & (sizeof(uintptr_t) - 1)) == 0) {
    // Word-at-a-time.
    /*@ loop invariant 0 <= length <= \at(length,Pre);
        loop invariant buffer == \at(buffer,Pre) + (\at(length,Pre) - length);
        loop assigns buffer, length;
        loop variant length;
    */
    while (length >= word_size) {
      // A byte array can be read by memcpy regardless of its effective type.
      uintptr_t chunk;
      memcpy(&chunk, buffer, sizeof(chunk));
      if ((chunk & HIGH_BIT_OF_EACH_BYTE) != 0) break;
      buffer += word_size;
      length -= word_size;
    }
  }
#if UINTPTR_MAX == UINT64_MAX
  // Thanks to Per Vognsen.  Explanation at
  // https://gist.github.com/pervognsen/218ea17743e1442e59bb60d29b1aa725
  uint64_t state = UTF_BASE;
  /*@ loop invariant 0 <= i <= length;
      loop assigns i, state;
      loop variant length - i;
  */
  for (intptr_t i = 0; i < length; i++) {
    unsigned char c = buffer[i];
    state = UTF_8_STATE_TABLE[c] >> (state & UTF_MASK);  // The '&' is optimized out.
  }
  return (state & UTF_MASK) == UTF_BASE;
#else
  uint32_t state = UTF_BASE;
  uint32_t allowed_nibbles = START;
  /*@ loop invariant 0 <= i <= length;
      loop assigns i, state, allowed_nibbles;
      loop variant length - i;
  */
  for (intptr_t i = 0; i < length; i++) {
    unsigned char c = buffer[i];
    int high_nibble = c >> 4;
    if ((allowed_nibbles & (1u << high_nibble)) == 0) return false;
    state = UTF_8_STATE_TABLE_32[high_nibble] >> (state & UTF_MASK);  // The '&' is optimized out.
    allowed_nibbles = MALFORMED_TABLE[c];
  }
  return (state & UTF_MASK) == UTF_BASE;
#endif
}

#ifdef __cplusplus
}  // namespace toit
#endif
