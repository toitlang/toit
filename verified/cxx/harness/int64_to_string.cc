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

// Pilot target (a), arithmetic leaf: PRIMITIVE(int64_to_string) of
// src/primitive_core.cc, the real body with ARGS(int64, value, int, base),
// for EVERY smi value and every base. The bases the body hands to snprintf
// (10, and 2/8/16 for non-negative values: printf_style_integer_to_string)
// are outside this harness: ESBMC's snprintf is a model. For the others
// (negative values in bases 2/8/16, every value in the other bases 3..36)
// the digit loop writes backwards into a 70-byte stack buffer.
// Process::allocate_string_or_error (src/process.cc) is defined here to
// capture the string.
//
// Properties, for all smi values (the arguments a smi-sized program passes
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
static char captured_copy[70];
static const char* captured;

namespace toit {
Object* Process::allocate_string_or_error(const char* content) {
  for (int i = 0; i < 70; i++) {
    captured_copy[i] = content[i];
    if (content[i] == 0) break;
  }
  captured = captured_copy;
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
  cxxv::World world;
  cxxv::make_world(&world);
  Smi* value_smi = cxxv::nondet_smi();
  word base = nondet_word();
  CXXV_ASSUME(Smi::is_valid(base));
  // Keep away from the snprintf paths (see the header comment).
  int64 value = Smi::value(value_smi);
  CXXV_ASSUME(base != 10);
#ifdef CXXV_BASE
  base = CXXV_BASE;  // One constant base per run: division by a constant.
#endif
  CXXV_ASSUME(!(value >= 0 && (base == 2 || base == 8 || base == 16)));
  Object* stack[2];
  stack[1] = value_smi;
  stack[0] = Smi::from(base);
  captured = null;
  Object* result = primitive_int64_to_string(world.process, &stack[1]);
  if (!(2 <= base && base <= 36)) {
    CXXV_ASSERT(result == cxxv::failure(Program::OUT_OF_RANGE_INDEX), "P2");
    return 0;
  }
  CXXV_ASSERT(captured != null, "P3: a string");
  if (value == 0) {
    CXXV_ASSERT(captured[0] == '0' && captured[1] == 0, "P3: zero");
    return 0;
  }
  bool negative = captured[0] == '-';
  CXXV_ASSERT(negative == (value < 0), "P3: sign");
  uint64 magnitude = 0;
  int i = negative ? 1 : 0;
  CXXV_ASSERT(captured[i] != '0', "P3: no leading zero");
  for (; i < 66 && captured[i] != 0; i++) {
    int d = digit_value(captured[i]);
    CXXV_ASSERT(d < base, "P3: a digit of the base");
    magnitude = magnitude * base + d;
  }
  CXXV_ASSERT(captured[i] == 0, "P3: terminated");
  uint64 expected = value < 0 ? -static_cast<uint64>(value) : static_cast<uint64>(value);
  CXXV_ASSERT(magnitude == expected, "P3: the digits denote the value");
  return 0;
}
