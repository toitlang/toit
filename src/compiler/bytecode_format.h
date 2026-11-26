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
//   1: the format the C++ interpreter runs (src/bytecodes.h). Selected with
//      -Xbytecode_format=1, TOIT_BYTECODE_FORMAT=1 or a build configured
//      with -DTOIT_BYTECODE_FORMAT=1. The type propagator interprets it, so
//      the first pass of -O2 and --propagate always generate format 1 in
//      memory (it is never written to a snapshot unless requested).
//   2: the revised format of the verified core, specified in
//      verified/spec/src/v2 and documented in verified/spec/format. The
//      default of builds with the verified core (docs/format2-migration.md).
//      The C++ interpreter cannot run it.
//
// Format 2 keeps the opcode numbers of format 1 for the instructions it
// shares, changes the operands of the frame instructions (returns, tail
// calls, non-local returns, backward branches, throw), drops LINK, UNLINK,
// NON_LOCAL_RETURN_WIDE and the four intrinsics, and reuses three of the
// freed numbers for TRY, LOAD_FIELD_THIS and STORE_FIELD_THIS. Method ids are
// indices into the method table (the order of the methods in the bytecodes),
// method headers are 2 bytes plus LEB128-encoded fields and carry the body
// length, and the bytecodes start with a 4-byte tag.
// Format 3, step 1 (verified/spec/format/22-format3-branches-frames.md):
// the short branches V2_BRANCH_S .. V2_BRANCH_BACK_S (interpreter_v2.h),
// chosen by Emitter::relax_branches. Format 3, step 3
// (verified/spec/format/23-format3-try.md): TRY calls its try block as a try
// block and the finally code has four slots (V2_FINALLY_SLOTS); the tag
// becomes TBC3. The selector (-Xbytecode_format=2, TOIT_BYTECODE_FORMAT=2)
// keeps its number: 2 selects the verified core's format, now version 3.
int bytecode_format();
void set_bytecode_format(int format);

// The format the user asked for: -Xbytecode_format=N if given, else
// TOIT_BYTECODE_FORMAT from the environment, else the build's default
// (TOIT_DEFAULT_BYTECODE_FORMAT, set by the CMake option
// TOIT_BYTECODE_FORMAT).
int requested_bytecode_format();
inline bool is_format2() { return bytecode_format() == 2; }

// Proposal (verified/spec/format/19-builtins-proposal.md): the format-2
// built-ins the compiler emits (-Xv2_builtins, or TOIT_V2_BUILTINS for
// measurements).
static const int V2_BUILTIN_REPEAT = 1 << 0;
static const int V2_BUILTIN_ARRAY_DO = 1 << 1;
static const int V2_BUILTIN_HASH_FIND = 1 << 2;
bool v2_builtin_enabled(int builtin);

// Format note 20: the compiler emits the unchecked twins of the field
// accesses (opcodes V2_FIRST_TWIN..), for trusted (first-party) programs
// only. On by default; off with -Xuntrusted (toit.compile --untrusted,
// toit.run --untrusted), -Xv2_unchecked=false or TOIT_V2_UNCHECKED=0. The
// verifier rejects them in untrusted programs.
bool v2_unchecked_enabled();
static const int V2_FIRST_TWIN = 104;
// The twin of a field access, or -1.
inline int v2_twin_of(int opcode) {
  if (7 <= opcode && opcode <= 13) return V2_FIRST_TWIN + opcode - 7;  // LOAD_FIELD .. STORE_FIELD_POP.
  if (opcode == 60) return V2_FIRST_TWIN + 7;                         // INVOKE_VIRTUAL_GET.
  if (opcode == 61) return V2_FIRST_TWIN + 8;                         // INVOKE_VIRTUAL_SET.
  if (opcode == 94) return V2_FIRST_TWIN + 9;                         // STORE_FIELD_THIS.
  return -1;
}

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
// Proposal (format note 19): the loop steps of `repeat` and `Array.do`,
// numbered like the format-1 intrinsics they replace.
static const Opcode V2_LOOP_REPEAT = INTRINSIC_SMI_REPEAT;
static const Opcode V2_LOOP_ARRAY = INTRINSIC_ARRAY_DO;
static const Opcode V2_HASH_FIND = INTRINSIC_HASH_FIND;
static const int V2_LOOP_STEP_LENGTH = 4;

// Format 3 (verified/spec/format/23-format3-try.md): TRY calls the try block
// as a try block; its finally code starts with four slots above the TRY's
// height: the value (the exception or a non-local return's value, else
// null), the two words of the unwinding token, and the reason (-2 for an
// exception, -1 otherwise). UNWIND pops the four. The distances are counted
// from the height after the four slots, like Interpreter::LINK_*_SLOT.
static const int V2_FINALLY_SLOTS = 4;
static const int V2_FINALLY_VALUE_SLOT = 4;
static const int V2_FINALLY_REASON_SLOT = 1;

// Method header of format 2 (format note 21): it ends at the method's
// entry, every field at a fixed distance from it (u16 little endian), in
// address order:
//    method:    [recv_end, unless V2_KIND_SINGLE] recv_start selector kind
//    accessor:  aux recv_end recv_start selector kind
//    lambda:    aux kind
//    block:     kind
// The kind byte: bits 0-1 the kind (0 method, 1 field accessor, 2 lambda,
// 3 block), bit 2 V2_KIND_SINGLE (a method whose receiver range is one
// class, end = start + 1, or none), the other bits zero. The selector
// offset and the receiver range start are 0xffff for none; aux is the
// captured count of a lambda, the field index of an accessor. The arity
// and the entry are the method's record in the method table (the
// program's last literal, V2MethodTable in interpreter_v2.h); a body ends
// at the next method's header. The max height is not in the header: the
// program's global max stack height bounds every method.
// The entries of methods, accessors and lambdas are odd (their headers
// start at even offsets), so that every u16 field is 2-byte aligned in the
// 2-byte aligned bytecodes: a pad byte (V2_PAD, never executed: a
// terminator, so that linear decoders see a well-formed body) ends the
// previous body where needed. Blocks have no u16 fields.
static const int V2_KIND_SINGLE = 1 << 2;
static const uint8 V2_PAD = RETURN_NULL;
// Entries have 24 bits.
static const int V2_MAX_BYTECODES = 0x1000000;
static const int V2_KIND_METHOD = 0;
static const int V2_KIND_FIELD_ACCESSOR = 1;
static const int V2_KIND_LAMBDA = 2;
static const int V2_KIND_BLOCK = 3;
static const int V2_NO_VALUE = 0xffff;

// The bytecodes of a program of the verified core start with this tag: TBC3
// since format 3 (verified/spec/format/23-format3-try.md). Program::is_format2
// accepts only it; any other TBC tag is a stale image and is refused.
static const int V2_TAG_SIZE = 4;
static const uint8 V2_TAG[V2_TAG_SIZE] = { 'T', 'B', 'C', '3' };

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
