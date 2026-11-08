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

#include "../top.h"
#include "../bytecodes.h"

namespace toit {
namespace compiler {

// The bytecode format the backend generates.
//
//   1: the format the C++ interpreter runs (src/bytecodes.h). The default.
//   2: the revised format of the verified core, specified in
//      verified/spec/src/v2 and documented in verified/spec/format.
//      Selected with -Xbytecode_format=2. The C++ interpreter cannot run it.
//
// Format 2 keeps the opcode numbers of format 1 for the instructions it
// shares, changes the operands of the frame instructions (returns, tail
// calls, non-local returns, backward branches, throw), drops LINK, UNLINK,
// NON_LOCAL_RETURN_WIDE and the four intrinsics, and reuses three of the
// freed numbers for TRY, LOAD_FIELD_THIS and STORE_FIELD_THIS. Method ids are
// indices into the method table (the order of the methods in the bytecodes),
// method headers are 16 bytes and carry the body length, and the bytecodes
// start with a 4-byte tag.
int bytecode_format();
void set_bytecode_format(int format);
inline bool is_format2() { return bytecode_format() == 2; }

// Sets the format for a scope and restores the previous one.
class BytecodeFormatScope {
 public:
  explicit BytecodeFormatScope(int format) : previous_(bytecode_format()) {
    set_bytecode_format(format);
  }
  ~BytecodeFormatScope() { set_bytecode_format(previous_); }

 private:
  int previous_;
};

// Format-2 opcodes that reuse numbers of format-1 opcodes.
static const Opcode V2_TRY = LINK;
static const Opcode V2_LOAD_FIELD_THIS = UNLINK;
static const Opcode V2_STORE_FIELD_THIS = NON_LOCAL_RETURN_WIDE;

// Method header of format 2 (little endian):
//    0  u8   arity
//    1  u8   kind (0 method, 1 field accessor, 2 lambda, 3 block)
//    2  u16  max height
//    4  u16  selector offset (0xffff: none)
//    6  u16  aux: captured count (lambda), field index (field accessor)
//    8  u16  receiver class-id range start (0xffff: no declared receiver)
//   10  u16  receiver class-id range end (exclusive)
//   12  u32  length of the body in bytes
static const int V2_HEADER_SIZE = 16;
static const int V2_KIND_METHOD = 0;
static const int V2_KIND_FIELD_ACCESSOR = 1;
static const int V2_KIND_LAMBDA = 2;
static const int V2_KIND_BLOCK = 3;
static const int V2_NO_VALUE = 0xffff;

// The bytecodes of a format-2 program start with this tag.
static const int V2_TAG_SIZE = 4;
static const uint8 V2_TAG[V2_TAG_SIZE] = { 'T', 'B', 'C', '2' };

// The strings the format-2 machine uses as the value of the exceptions it
// raises itself (instead of calling the failure entry points). They are
// the literals 2 to 6 of a format-2 program, right after true and false.
#define V2_FAILURE_STRINGS(F)            \
  F(LOOKUP_FAILED)                       \
  F(AS_CHECK_FAILED)                     \
  F(CODE_INVOCATION_FAILED)              \
  F(INVALID_PROGRAM)                     \
  F(PRIMITIVE_LOOKUP_FAILED)             \

} // namespace toit::compiler
} // namespace toit
