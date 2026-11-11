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

// Pilot target (a): PRIMITIVE(int_parse) of src/primitive_core.cc, the real
// function body with the real ARGS(Blob, ..., word, ..., int, ...) argument
// decoding (src/primitive.h macros, Object::byte_content of
// src/objects.cc), on arbitrary arguments: the blob is a string or byte
// array (internal or external) of any length up to CXXV_MAX_BLOB with
// arbitrary bytes; from, to and the block argument are arbitrary objects
// (a smi, or a non-smi); the receiver of the result is observed through
// Primitive::allocate_large_integer, which the harness defines (its real
// definition, in src/primitive.cc, allocates).
//
// Properties, for all such arguments:
//  P1 no out-of-bounds access, no invalid pointer, no signed overflow or
//     UB shift (memory safety and no UB);
//  P2 full functional contract: the result is OUT_OF_RANGE when the range
//     is not 0 <= from < to <= length or is longer than 18 bytes;
//     otherwise INVALID_ARGUMENT exactly when the bytes are not an optional
//     '-' followed by digits and underscores that start and end with a
//     digit, and else the integer they denote (reference: parse_reference).

// RAW drops primitive_core.cc's include of compiler/compiler.h (unused there).
#define RAW
// The fewer heap objects, the cheaper every field access (tagged pointers:
// each access is resolved against every object). from/to/block are smis;
// a non-smi takes the type check alone.
#define CXXV_NO_ODDBALLS
#define private public
#define protected public
#include "prelude.h"
#include "primitive_core.cc"
#include "objects.cc"
#undef private
#undef protected

#include "constants.h"
#include "heap_model.h"

using namespace toit;

#ifndef CXXV_MAX_BLOB
#define CXXV_MAX_BLOB 64
#endif

// The value the primitive asked to box as a large integer.
static int64 boxed_value;
static Object* boxed_marker;

Object* Primitive::allocate_large_integer(int64 value, Process* process) {
  boxed_value = value;
  return boxed_marker;
}

// Independent reference of the accepted syntax and the value (P2).
// Returns false for a syntax error.
static bool parse_reference(const uint8* in, word from, word to, int64* result) {
  bool negative = in[from] == '-';
  word start = negative ? from + 1 : from;
  if (start == to) return false;
  if (!('0' <= in[start] && in[start] <= '9')) return false;
  if (!('0' <= in[to - 1] && in[to - 1] <= '9')) return false;
  int64 value = 0;
  for (word i = start; i < to; i++) {
    uint8 c = in[i];
    if ('0' <= c && c <= '9') {
      value = value * 10 + (c - '0');  // At most 18 digits: below 10^18.
    } else if (c != '_') {
      return false;
    }
  }
  *result = negative ? -value : value;
  return true;
}

static Object* nondet_argument(cxxv::World* world) {
  return cxxv::nondet_smi();
}

int main() {
  cxxv::cxxv_constants();
  cxxv::World world;
  cxxv::make_world(&world);
  boxed_marker = reinterpret_cast<Object*>(world.process);  // Any non-smi.

  Object* input = cxxv::nondet_blob(CXXV_MAX_BLOB);
  // Arguments are on the stack from __args[0] downwards (src/primitive.h).
  Object* stack[4];
  stack[3] = input;
  stack[2] = nondet_argument(&world);  // from
  stack[1] = nondet_argument(&world);  // to
  stack[0] = nondet_argument(&world);  // block_arg_dont_use_this
  Object* result = primitive_int_parse(world.process, &stack[3]);

  // Observe the outcome against the reference.
  if (!is_smi(stack[2]) || !is_smi(stack[1])) {
    CXXV_ASSERT(result == cxxv::failure(Program::WRONG_OBJECT_TYPE_INDEX), "P2: from/to not smis");
    return 0;
  }
  Blob blob;
  CXXV_ASSERT(input->byte_content(world.program, &blob, STRINGS_OR_BYTE_ARRAYS), "the input is a blob");
  word from = Smi::value(stack[2]);
  word to = Smi::value(stack[1]);
  if (!is_smi(stack[0])) return 0;  // The int argument's own failure.
  word block = Smi::value(stack[0]);
  if (block != static_cast<int>(block)) {
    CXXV_ASSERT(result == cxxv::failure(Program::OUT_OF_RANGE_INDEX), "P2: block arg out of int range");
    return 0;
  }
  if (!(0 <= from && from < to && to <= blob.length()) || to - from > 18) {
    CXXV_ASSERT(result == cxxv::failure(Program::OUT_OF_RANGE_INDEX), "P2: bad range is OUT_OF_RANGE");
    return 0;
  }
  int64 expected;
  if (!parse_reference(blob.address(), from, to, &expected)) {
    CXXV_ASSERT(result == cxxv::failure(Program::INVALID_ARGUMENT_INDEX), "P2: syntax error is INVALID_ARGUMENT");
    return 0;
  }
  int64 actual = is_smi(result) ? Smi::value(result) : boxed_value;
  CXXV_ASSERT(is_smi(result) || result == boxed_marker, "P2: an integer result");
  CXXV_ASSERT(actual == expected, "P2: the value is the reference value");
  return 0;
}
