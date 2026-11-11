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

// Is the C transliteration that Frama-C/WP proves
// (verified/cxx/framac/utf_8_to_16.c) the real Utils::utf_8_to_16? ESBMC
// compiles both in one translation unit and checks, for every input of at
// most N bytes and every output length up to N + 1, that they return the
// same value and write the same output. This is what keeps a deductive
// proof of a C copy honest: the copy is tied to the real code (bounded).

#include "prelude.h"
#include "utils.cc"
#include "constants.h"

#include <stdlib.h>

#include "../framac/utf_8_to_16.c"

#ifndef N
#define N 6
#endif

int main() {
  cxxv::cxxv_constants();
  word len = nondet_int();
  CXXV_ASSUME(0 <= len && len <= N);
  uint8 in[N];
  word out_len = nondet_int();
  CXXV_ASSUME(0 <= out_len && out_len <= N + 1);
  uint16 out_a[N + 1];
  uint16 out_b[N + 1];
  for (int i = 0; i < N + 1; i++) out_b[i] = out_a[i] = nondet_ushort();
  bool with_output = nondet_bool();
  word a = toit::Utils::utf_8_to_16(in, len, with_output ? out_a : nullptr, out_len);
  word b = utf_8_to_16(in, len, with_output ? out_b : nullptr, out_len);
  CXXV_ASSERT(a == b, "same result");
  for (int i = 0; i < N + 1; i++) CXXV_ASSERT(out_a[i] == out_b[i], "same output");
  return 0;
}
