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

// Format-2 programs (verified/spec/format/README.md) and the interface to
// the verified interpreter core (verified/core) that runs them.
//
// A format-2 program is recognized by the tag at the start of its
// bytecodes (Program::is_format2). When a process group is created for it,
// its method table is decoded from the method headers and checked
// (V2MethodTable). The interpreter's run() and prepare_process() hand
// format-2 processes to the core (interpreter_v2.cc), which owns the run
// loop and calls back into C++ only through the toit_v2_* functions below
// (allocation and GC, stack growth, C++ primitives). See
// verified/core/DESIGN.md for the contract.

#include "top.h"

namespace toit {

class Program;
class Process;

// One entry of the method table: method `i` is the `i`-th method in the
// bytecodes. Must match `V2Method` in verified/core/src/layout.rs (checked
// by verified/layout_check.cc).
struct V2Method {
  uint32 entry;       // Absolute bci of the first instruction.
  uint32 end;         // Absolute bci after the last instruction.
  uint16 selector;    // Selector offset, 0xffff for none.
  uint16 aux;         // Captured count (lambda) or field index (accessor).
  uint16 recv_start;  // Receiver class-id range, 0xffff for none.
  uint16 recv_end;
  uint8 arity;
  uint8 kind;         // 0 method, 1 field accessor, 2 lambda, 3 block.
  uint16 unused;
};

static const int V2_KIND_METHOD = 0;
static const int V2_KIND_FIELD_ACCESSOR = 1;
static const int V2_KIND_LAMBDA = 2;
static const int V2_KIND_BLOCK = 3;
static const int V2_NO_VALUE = 0xffff;
static const int V2_OPCODE_COUNT = 101;
static const int V2_PRIMITIVE_LENGTH = 4;

// Instruction lengths of format 2, in opcode order
// (verified/spec/src/v2/bytecodes.rs, OPCODE_LENGTHS2).
static const uint8 V2_OPCODE_LENGTHS[V2_OPCODE_COUNT] = {
  2, 3, 2, 2, 2, 2, 2, 2, 3, 2, 2, 2, 3, 2,  // 0..13
  1, 1, 1, 1, 1, 1,                          // LOAD_LOCAL_0..5
  2, 3, 1, 1, 2, 1, 2, 3, 5, 5,              // 20..29
  2, 3, 2, 3, 1, 2, 3, 1, 2, 2,              // 30..39
  2, 1,                                      // POP, POP_1
  2, 3,                                      // ALLOCATE
  2, 3, 2, 3, 2, 3, 2, 3, 2,                 // 44..52
  3, 3, 2, 1, 1,                             // 53..57
  4, 5, 3, 3,                                // 58..61
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3,  // 62..80
  3, 3, 3, 3, 3, 3, 3, 3,                    // 81..88: BRANCH*, BRANCH_BACK*
  4, 1, 1, 1, 1, 2, 6, 1, 1, 2, 1, 2,        // 89..100
};

// The decoded method table of a format-2 program, owned by its process
// group. Decoding is the trusted loader of format note 15 plus the table
// checks of the reference loader (verified/spec/src/interp/loader.rs,
// method_table_v2 and check_tables_v2).
class V2MethodTable {
 public:
  ~V2MethodTable();

  // Decodes and checks the method table. Returns null (and prints the reason
  // to stderr) if the program is malformed or the allocation fails. With
  // [untrusted], HALT 2 and HALT 3 are rejected, as the format-1 verifier
  // does for untrusted programs.
  static V2MethodTable* compute(Program* program, bool untrusted = false);

  // The format-2 stand-in for the structural verifier until the Phase 3
  // verifier is integrated: decodes and checks the table, then frees it.
  static bool verify(Program* program, bool untrusted);

  const V2Method* methods() const { return methods_; }
  word length() const { return length_; }

  // The method index of the given entry point, or -1.
  word entry_method(Program* program, int entry_point_index) const;

  bool is_valid(word index) const { return 0 <= index && index < length_; }

  // The index of the method whose body starts at [entry], or -1.
  word index_of_entry(word entry) const;
  const V2Method& at(word index) const { return methods_[index]; }

 private:
  V2MethodTable(V2Method* methods, word length) : methods_(methods), length_(length) {}

  V2Method* const methods_;
  const word length_;
};

}  // namespace toit

extern "C" {

// The program tables, as the core sees them. Must match `ProgramTables` in
// verified/core/src/ffi.rs (checked by verified/layout_check.cc).
struct toit_v2_program {
  const uint8* bytecodes;
  uword bytecodes_length;
  const toit::V2Method* methods;
  uword methods_length;
  const int32* dispatch;
  uword dispatch_length;
  const uint16* class_bits;
  uword class_bits_length;
  const uint16* class_check_ids;
  uword class_check_ids_length;
  const uint16* interface_check_offsets;
  uword interface_check_offsets_length;
  const int32* invoke_offsets;      // 19 entries, INVOKE_EQ..INVOKE_SIZE.
  const int32* entry_points;        // 9 dispatch-table indexes.
  const uword* builtin_class_ids;   // 23 smis.
  const uword* roots;               // Program::ROOT_COUNT objects.
  uword roots_length;
  const uword* literals;
  uword literals_length;
  uword* globals;                   // The process' global variables.
  uword globals_length;
  uword program_heap_start;         // Read-only objects are in
  uword program_heap_size;          //   [start, start + size).
  uword remembered_set_bias;        // GcMetadata::remembered_set_bias().
  uword global_max_height;          // Bounds every method's height.
  uword stack_array_word;           // Word offset of a Stack's array.
};

// The context of one run of a format-2 process. Must match `Context` in
// verified/core/src/ffi.rs.
struct toit_v2_context {
  void* process;
  toit_v2_program program;
  const void* watermark;                  // &Interpreter::watermark_.
  uword preempt_a_lot;
  // Out.
  uword result_state;               // Interpreter::Result::State.
  int64 result_value;
};

// Results of the helpers.
static const uword TOIT_V2_OK = 0;
static const uword TOIT_V2_STACK_OVERFLOW = 1;
static const uword TOIT_V2_OUT_OF_MEMORY = 2;
static const uword TOIT_V2_PRIMITIVE_SUCCESS = 0;
static const uword TOIT_V2_PRIMITIVE_FAILURE = 1;
static const uword TOIT_V2_PRIMITIVE_THROW = 2;
static const uword TOIT_V2_PRIMITIVE_MISSING = 0;
static const uword TOIT_V2_PRIMITIVE_FOUND = 1;

// Reports (stderr) of the core.
static const uword TOIT_V2_REPORT_STUCK = 0;
static const uword TOIT_V2_REPORT_UNCAUGHT = 1;
static const uword TOIT_V2_REPORT_TASK_RETURNED = 2;

// Implemented by the core (verified/core/src/ffi.rs).
#ifdef TOIT_VERIFIED_CORE
uword toit_v2_run(toit_v2_context* context);
uword toit_vcore_layout_count();
bool toit_vcore_layout_entry(uword i, const char** name, uword* value);
uword toit_vcore_opcode_length(uword opcode);
#endif

// Implemented in C++ (interpreter_v2.cc), called by the core. Every one that
// may garbage collect is marked; the core stores its stack state into the
// task's Stack object before calling it and re-reads everything after it.
// See verified/core/DESIGN.md, "FFI contract".

// The current task's Stack object (a tagged pointer).
uword toit_v2_current_stack(void* process);
// MAY GC. Allocates an instance of the class (fields null). 0 on failure.
uword toit_v2_allocate_instance(void* process, uword class_id);
// MAY GC. Allocates a double with the given bits. 0 on failure.
uword toit_v2_allocate_double(void* process, uint64 bits);
// MAY GC. Allocates an Exception_ with the given value (a program-heap
// object) and the encoded stack trace of the current task. 0 on failure.
uword toit_v2_allocate_exception(void* process, uword value);
// MAY GC. Allocates an array of [length] elements, all [filler]. 0 on failure.
uword toit_v2_allocate_array(void* process, uword length, uword filler);
// MAY GC. Replaces the current task's stack by one with at least [needed]
// free words between the frames and the object stack.
uword toit_v2_grow_stack(void* process, uword needed);
// Looks up primitive (module, index) in the process' policy.
uword toit_v2_lookup_primitive(void* process, uword module, uword index,
                                     const void** entry, uword* arity);
// MAY GC. Calls the C++ primitive whose arguments start at object-stack
// position [first_argument] (counted from the bottom). May switch the
// current task (task_transfer).
uword toit_v2_call_primitive(void* process, const void* entry, uword arity,
                                   uword first_argument, uword* result);
void toit_v2_report(void* process, uword kind, uword bci, uword detail);

}  // extern "C"
