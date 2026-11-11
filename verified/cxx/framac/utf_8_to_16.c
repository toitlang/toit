/* Copyright (C) 2026 Toit contributors.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; version
 * 2.1 only.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * The license can be found in the file `LICENSE` in the top level
 * directory of this repository.
 */

/* Frama-C/WP pilot (verified/CXX-VERIFICATION-PILOT.md, "Deductive
 * tools"): a C transliteration of Utils::utf_8_to_16 and its two helpers
 * (src/utils.cc, src/utils.h), statement by statement: `word` is a
 * ptrdiff_t, the class constants are macros, `static` member functions are
 * functions. The C++ is not compiled by Frama-C (its C++ front end,
 * frama-clang, is not part of this pilot); the transliteration's agreement
 * with the C++ is checked separately by ESBMC on bounded inputs
 * (verified/cxx/harness/utf_8_to_16_equiv.cc includes this file and the
 * real utils.cc in one translation unit).
 *
 * WP proves, for ALL lengths (unbounded): no runtime error (-wp-rte:
 * memory access, signed overflow, shifts), the reads stay inside the input,
 * the writes inside the output, and the result is -1 or in [0, length].
 * With CXXV_MUTANT the code before 07c24665 (the over-read): WP must fail.
 */

#include <stddef.h>
#include <stdint.h>

typedef ptrdiff_t word;
typedef uint8_t uint8;
typedef uint16_t uint16;

#define MAX_ASCII 0x7f
#define UTF_8_BITS_PER_BYTE 6
#define UTF_8_MASK 0x3f

/*@ assigns \nothing;
    ensures prefix <= MAX_ASCII ==> \result == 1;
    ensures prefix > MAX_ASCII ==> 1 <= \result <= 8;
*/
static word bytes_in_utf_8_sequence(unsigned char prefix) {
  if (prefix <= MAX_ASCII) return 1;
  word count = 0;
  word mask = 0x80;
  /*@ loop invariant 0 <= count <= 8;
      loop invariant mask == (0x80 >> count);
      loop invariant \forall integer k; 0 <= k < count ==> (prefix & (0x80 >> k)) != 0;
      loop assigns count, mask;
      loop variant 8 - count;
  */
  while ((prefix & mask) != 0) {
    count++;
    mask >>= 1;
  }
  /*@ assert count >= 1; */
  return count;
}

/*@ requires prefix > MAX_ASCII;
    requires 2 <= n <= 4;
    assigns \nothing;
    ensures 0 <= \result < 64;
*/
static word payload_from_prefix_n(unsigned char prefix, word n) {
  return prefix & ((1 << (7 - n)) - 1);
}

#ifndef CXXV_MUTANT
/* The real payload_from_prefix calls bytes_in_utf_8_sequence again; the
 * caller has the count, so the transliteration passes it (same value). */
#define PAYLOAD(prefix, count) payload_from_prefix_n(prefix, count)
#else
/*@ requires prefix > MAX_ASCII;
    assigns \nothing;
*/
static word payload_from_prefix(unsigned char prefix) {
  word n_byte_sequence = bytes_in_utf_8_sequence(prefix);
  return prefix & ((1 << (7 - n_byte_sequence)) - 1);
}
#define PAYLOAD(prefix, count) payload_from_prefix(prefix)
#endif

/*@ requires 0 <= length <= 0x3fffffff;
    requires \valid_read(input + (0 .. length - 1));
    requires output == \null || (0 <= output_length && \valid(output + (0 .. output_length - 1)));
    requires output != \null ==> \separated(input + (0 .. length - 1), output + (0 .. output_length - 1));
    assigns output[0 .. output_length - 1];
    ensures \result == -1 || 0 <= \result <= length;
    ensures output == \null ==> 0 <= \result <= length;
*/
word utf_8_to_16(const uint8* input, word length, uint16* output, word output_length) {
  word size = 0;
  /*@ loop invariant 0 <= i <= length;
      loop invariant 0 <= size <= i;
      loop invariant output != \null ==> size <= output_length;
      loop assigns i, size, output[0 .. output_length - 1];
      loop variant length - i;
  */
  for (word i = 0; i < length; ) {
    uint8 prefix = input[i];
    word count = bytes_in_utf_8_sequence(prefix);
    int c;
#ifndef CXXV_MUTANT
    if (prefix > MAX_ASCII && (count < 2 || count > 4 || count > length - i)) {
      c = 0xfffd;
      count = 1;
    } else
#endif
    if (prefix > MAX_ASCII) {
      c = PAYLOAD(prefix, count);
      /*@ loop invariant 1 <= j <= count;
          loop invariant 0 <= c < (1 << (6 * j + 1));
          loop assigns j, c;
          loop variant count - j;
      */
      for (word j = 1; j < count; j++) {
        c <<= UTF_8_BITS_PER_BYTE;
        c |= input[i + j] & UTF_8_MASK;
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
      /* Surrogate pair. */
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
