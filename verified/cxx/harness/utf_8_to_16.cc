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

// Pilot target (d): Utils::utf_8_to_16 (src/utils.cc), the conversion of
// the string_to_utf_16 primitive, on arbitrary bytes (a crafted program
// can hold strings that aren't valid UTF-8: commit 07c24665 fixed an
// over-read of up to 7 bytes).
//
// The real src/utils.cc is compiled unmodified (with objects.h and
// process.h). Input: N nondeterministic bytes in a malloced block of
// exactly `len` bytes (so any read past the end is an out-of-bounds
// access for the tool), `len` nondeterministic in [0, N].
//
// Properties, for every input of at most N bytes:
//  P1 no out-of-bounds read or write, no signed overflow, no UB shift
//     (the tool's standard checks with --overflow-check);
//  P2 the sizing pass (output null) returns 0 <= n <= len;
//  P3 the writing pass with an output of exactly n units returns n and
//     writes only inside it (the primitive allocates 2n bytes from the
//     first pass and writes with the second: if the passes disagreed, the
//     write would overflow the byte array);
//  P4 with a shorter output it returns -1 and writes only inside it.

#include "prelude.h"
#include "utils.cc"
#include "constants.h"

#include <stdlib.h>

using namespace toit;

#ifndef N
#define N 8
#endif

int main() {
  cxxv::cxxv_constants();
  word len = nondet_int();
  CXXV_ASSUME(0 <= len && len <= N);
  uint8* in = static_cast<uint8*>(malloc(len == 0 ? 1 : len));
  CXXV_ASSUME(in != null);
  for (word i = 0; i < len; i++) in[i] = nondet_uchar();

  word n = Utils::utf_8_to_16(in, len);
  CXXV_ASSERT(0 <= n && n <= len, "P2: sizing pass result in [0, len]");

  uint16* out = static_cast<uint16*>(malloc((n == 0 ? 1 : n) * sizeof(uint16)));
  CXXV_ASSUME(out != null);
  word m = Utils::utf_8_to_16(in, len, out, n);
  CXXV_ASSERT(m == n, "P3: writing pass agrees with the sizing pass");

  if (n > 0) {
    word short_length = nondet_int();
    CXXV_ASSUME(0 <= short_length && short_length < n);
    word k = Utils::utf_8_to_16(in, len, out, short_length);
    CXXV_ASSERT(k == -1, "P4: a short output is refused");
  }
  free(out);
  free(in);
  return 0;
}
