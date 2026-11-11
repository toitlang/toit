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

/* CBMC on the C transliteration of Utils::utf_8_to_16 (CBMC's C++ front
 * end cannot parse the VM's headers: it fails on libstdc++'s <type_traits>).
 * Same properties as verified/cxx/harness/utf_8_to_16.cc. Run:
 *   cbmc utf_8_to_16_harness.c --unwind 10 --pointer-check --bounds-check
 *        --signed-overflow-check --undefined-shift-check
 *        --unwinding-assertions [-DCXXV_MUTANT]
 */

#include <stdlib.h>
#include "../framac/utf_8_to_16.c"

#ifndef N
#define N 8
#endif

int nondet_int(void);
unsigned char nondet_uchar(void);

int main(void) {
  word len = nondet_int();
  __CPROVER_assume(0 <= len && len <= N);
  uint8* in = malloc(len == 0 ? 1 : len);
  __CPROVER_assume(in != NULL);
  for (word i = 0; i < len; i++) in[i] = nondet_uchar();
  word n = utf_8_to_16(in, len, NULL, 0);
  __CPROVER_assert(0 <= n && n <= len, "P2");
  uint16* out = malloc((n == 0 ? 1 : n) * sizeof(uint16));
  __CPROVER_assume(out != NULL);
  __CPROVER_assert(utf_8_to_16(in, len, out, n) == n, "P3");
  return 0;
}
