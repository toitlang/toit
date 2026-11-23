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

// Calls the native int64_to_string primitive with a tagged input and radix.
// Capture the explicit-length allocation before its source buffer expires.
// The independent parse below checks the bytes given to the allocator.
//
//// Properties, for all smi values (the arguments a smi-sized program passes
// without a large integer; the int64 range is the same code) and all
// bases:
//  P1 no write outside the buffer, no signed overflow, no division by zero;
//  P2 bases outside 2..36 are OUT_OF_RANGE;
//  P3 the digits are a correct base representation: parsing them back
//     gives the value (reference: an independent accumulating parse).

#define RAW
#define CXXV_NO_ODDBALLS
#define private public
#define protected public
#include "prelude.h"
#include "primitive_core.cc"
#undef private
#undef protected

#include "constants.h"
#include "heap_model.h"

using namespace toit;

// A copy: the primitive formats into its own stack buffer.
static char captured[65];
static word captured_length;
extern Process format_process;

namespace toit {
Object* Process::allocate_string_or_error(const char* content, word length) {
  CXXV_ASSERT(1 <= length && length <= 65, "P1: output fits including sign");
  memcpy(captured, content, length);
  captured_length = length;
  return Smi::from(0);
}
}  // namespace toit

static int digit_value(char c) {
  if ('0' <= c && c <= '9') return c - '0';
  if ('a' <= c && c <= 'z') return c - 'a' + 10;
  return 99;
}

int main() {
  cxxv::cxxv_constants();
  Smi* value_smi = cxxv::nondet_smi();
  word base = nondet_word();
  CXXV_ASSUME(Smi::is_valid(base));
  int64 value = Smi::value(value_smi);
#ifdef CXXV_BASE
  base = CXXV_BASE;  // One constant base per run: division by a constant.
#endif
  Object* stack[2];
  stack[1] = value_smi;
  stack[0] = Smi::from(base);
  captured_length = 0;
  Object* result = primitive_int64_to_string(&format_process, &stack[1]);
  if (!(2 <= base && base <= 36)) {
    CXXV_ASSERT(result == cxxv::failure(Program::OUT_OF_RANGE_INDEX), "P2");
    return 0;
  }
  CXXV_ASSERT(captured_length > 0, "P3: a string");
  if (value == 0) {
    CXXV_ASSERT(captured[0] == '0' && captured_length == 1, "P3: zero");
    return 0;
  }
  bool negative = captured[0] == '-';
  CXXV_ASSERT(negative == (value < 0), "P3: sign");
  uint64 magnitude = 0;
  int i = negative ? 1 : 0;
  CXXV_ASSERT(captured[i] != '0', "P3: no leading zero");
  for (; i < captured_length; i++) {
    int d = digit_value(captured[i]);
    CXXV_ASSERT(d < base, "P3: a digit of the base");
    magnitude = magnitude * base + d;
  }
  uint64 expected = value < 0 ? static_cast<uint64>(-(value + 1)) + 1 : static_cast<uint64>(value);
  CXXV_ASSERT(magnitude == expected, "P3: the digits denote the value");
  return 0;
}
