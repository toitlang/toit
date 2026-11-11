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

// LLVM-level variant of utf_8_to_16.cc for crux-llvm (verified/cxx/crux.sh):
// the harness is compiled with clang to LLVM bitcode and linked with the
// bitcode of the real src/utils.cc, compiled separately with the VM's own
// flags; crux-llvm then executes the bitcode symbolically. The properties
// are those of utf_8_to_16.cc (P1-P4), for inputs of at most N bytes.

#include <stdint.h>
#include <stdlib.h>
extern "C" {
#include <crucible.h>
}

#include "top.h"
#include "utils.h"

using namespace toit;

#ifndef N
#define N 6
#endif

int main() {
  word len = crucible_uint64_t("len");
  assuming(0 <= len && len <= N);
  uint8* in = static_cast<uint8*>(malloc(len == 0 ? 1 : len));
  for (word i = 0; i < N; i++) {
    if (i < len) in[i] = crucible_uint8_t("byte");
  }
  word n = Utils::utf_8_to_16(in, len);
  check(0 <= n && n <= len);
  uint16* out = static_cast<uint16*>(malloc((n == 0 ? 1 : n) * sizeof(uint16)));
  check(Utils::utf_8_to_16(in, len, out, n) == n);
  if (n > 0) {
    word short_length = crucible_uint64_t("short");
    assuming(short_length < static_cast<size_t>(n));
    check(Utils::utf_8_to_16(in, len, out, short_length) == -1);
  }
  free(out);
  free(in);
  return 0;
}
