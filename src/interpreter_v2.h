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
static const int V2_OPCODE_COUNT = 114;
static const int V2_PRIMITIVE_LENGTH = 4;
// Literals 0..7: true, false and the five failure values (format note 5).
static const int V2_FAILURE_LITERALS = 7;
// The core and the loader refuse bytecodes and method tables this large.
static const int V2_MAX_TABLE = 0x10000000;

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
  4, 4, 5,                                   // 101..103: LOOP_REPEAT, LOOP_ARRAY, HASH_FIND (proposal, note 19)
  2, 3, 2, 2, 2, 3, 2, 3, 3, 2,              // 104..113: the unchecked twins of the field accesses (note 20)
};

// The decoded method table of a format-2 program, owned by its process
// group. Decoding is the trusted loader of format note 15 (the reference
// is method_table_v2 in verified/spec/src/interp/loader.rs). It checks
// only what is needed to build the table; the structural verifier
// (verifier_v2.h) checks the program, on this table, before an untrusted
// program runs.
class V2MethodTable {
 public:
  ~V2MethodTable();

  // Decodes the method table. Returns null (and prints the reason to
  // stderr) if the headers are malformed or the allocation fails.
  static V2MethodTable* compute(Program* program);

  // Whether untrusted containers may be in format 1 (and run on the C++
  // interpreter): -Xuntrusted_format1 or TOIT_UNTRUSTED_FORMAT1=1. By
  // default untrusted containers must be in format 2.
  static bool untrusted_format1_allowed();

  const V2Method* methods() const { return methods_; }
  word length() const { return length_; }

  // The method index of the given entry point, or -1.
  word entry_method(Program* program, int entry_point_index) const;

  bool is_valid(word index) const { return 0 <= index && index < length_; }

  // The absolute bci of the header of a valid method (methods follow each
  // other, the first one after the tag). Format-2 method ids in the debug
  // information (tools/snapshot.toit) are header positions.
  word header_of(word index) const { return index == 0 ? 4 : methods_[index - 1].end; }

  // The index of the method whose body starts at [entry], or -1.
  word index_of_entry(word entry) const;
  const V2Method& at(word index) const { return methods_[index]; }

  // The launch-time verifier (V2Verifier::verify, verified/vmverify)
  // accepted the program on exactly this table: 0 not verified, 1 under
  // the untrusted rules, 2 under the trusted rules. Set only by the
  // verifier's accept path; the verified run loop of the core runs only
  // for a table it accepted (Interpreter::run_v2, TOIT_V2_ACCEPTED).
  uword verified() const { return verified_; }
  void mark_verified(bool trusted) { verified_ = trusted ? 2 : 1; }

  // Whether a process with this table runs on the verified loop: accepted
  // under the untrusted rules, or under the trusted rules for a trusted
  // process.
  bool runs_verified(bool untrusted) const {
    return verified_ == 1 || (verified_ == 2 && !untrusted);
  }

  // Whether the core's checked loop is linked (TOIT_VERIFIED_CORE_CHECKED_LOOP,
  // hosts). Without it (devices) only programs the verifier accepted run in
  // format 2: ProcessGroup::create refuses the others.
  static bool checked_loop_linked() {
#ifdef TOIT_VERIFIED_CORE_CHECKED_LOOP
    return true;
#else
    return false;
#endif
  }

  // Whether a trusted process whose table the launch did not verify runs on
  // the verified loop (TOIT_V2_TRUSTED), on the assumption that the
  // verifier would accept the compiler's output: we trust the compiler for
  // first-party code (verified/core/EXPERIMENT-trusted.md). On by default;
  // TOIT_TRUSTED_CHECKED_LOOP=1 keeps such programs on the checked loop
  // (hosts only, for comparisons).
  static bool trusted_on_verified_loop();

  // Whether launches verify trusted format-2 programs although
  // -Xverify/TOIT_VERIFY is off: debug builds do, as a check on the
  // compiler (a rejected trusted program does not run).
  static bool verify_trusted_by_default() {
#ifdef TOIT_DEBUG
    return true;
#else
    return false;
#endif
  }

 private:
  V2MethodTable(V2Method* methods, word length) : methods_(methods), length_(length) {}

  V2Method* const methods_;
  const word length_;
  uword verified_ = 0;
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
  // The program was accepted by the launch verification (untrusted
  // programs, or any program with -Xverify / TOIT_VERIFY=1). Only then does
  // the core run its verified handlers, which rely on the verifier's
  // guarantees instead of run-time checks; otherwise it runs the checked
  // handlers (verified/core/DESIGN.md, "Accepted programs").
  uword accepted;
  // PrimitivePolicy::core_arities of the process' policy: entry i is the arity
  // of core primitive i plus one if the policy resolves it to the VM's own
  // primitive (the core may run its Rust port), else 0.
  const uint8* core_arities;
  uword core_arities_length;
  // ObjectHeap::v2_epoch_address of the process: the core compares it around
  // C++ primitive calls (toit_v2_primitive).
  const uword* epoch;
  // The unchecked mode of trusted programs: the core does not check field
  // accesses (verified/core/EXPERIMENT-trusted.md). TRUSTED: never set for
  // an untrusted process.
  uword unchecked;
  // ObjectHeap::v2_new_space_top_address and v2_new_space_limit_address of
  // the process, and the chunk-end sentinel word: the core allocates
  // instances and doubles inline with the new-space fast path
  // (SemiSpace::try_allocate) and calls the allocation helpers below only
  // when it fails (verified/core/TRUSTED.md, "Inline allocation").
  uword* new_space_top;
  const uword* new_space_limit;
  uword new_space_sentinel;
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
static const uword TOIT_V2_PRIMITIVE_ABSENT = 3;

// `toit_v2_context.accepted` for a program the launch-time verifier accepted
// on the table the process runs (V2MethodTable::verified); any other value
// runs the checked loop. A distinct word, not a boolean, so that no other
// nonzero value selects the verified loop.
static const uword TOIT_V2_ACCEPTED = 0x56455249;  // "VERI"

// `toit_v2_context.accepted` for a trusted program (system process,
// first-party code) the launch did not verify: it runs on the verified loop
// on the assumption that the compiler's output would be accepted (we trust
// the compiler for first-party code; verified/core/EXPERIMENT-trusted.md).
static const uword TOIT_V2_TRUSTED = 0x54525354;  // "TRST"

// Messages of the exceptions the core raises (the trace's message, as the
// format-1 failure entry points of lib/core/exceptions.toit encode it).
static const uword TOIT_V2_MESSAGE_NONE = 0;       // The empty string.
static const uword TOIT_V2_MESSAGE_WORD = 1;       // words[0].
static const uword TOIT_V2_MESSAGE_ARRAY = 2;      // An array of the words.
static const uword TOIT_V2_MESSAGE_PRIMITIVE = 3;  // "Failed to find primitive m:i".
static const uword TOIT_V2_MESSAGE_MAX_WORDS = 4;

// Reports (stderr) of the core.
static const uword TOIT_V2_REPORT_STUCK = 0;
static const uword TOIT_V2_REPORT_UNCAUGHT = 1;
static const uword TOIT_V2_REPORT_TASK_RETURNED = 2;
// Detail: the opcode of the instruction at bci, which is about to run.
// Only reported while toit_v2_tracing returns nonzero.
static const uword TOIT_V2_REPORT_TRACE = 3;

// Implemented by the core (verified/core/src/ffi.rs).
#ifdef TOIT_VERIFIED_CORE
uword toit_v2_run(toit_v2_context* context);
// Whether core primitive `index` has a Rust port in the core.
uword toit_v2_core_ported(uword index);
uword toit_vcore_layout_count();
bool toit_vcore_layout_entry(uword i, const char** name, uword* value);
uword toit_vcore_opcode_length(uword opcode);
uword toit_vcore_prim_count();
bool toit_vcore_prim_entry(uword i, const char** name, uword* index, uword* arity);
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
// object) and the encoded stack trace of the current task, whose message is
// built from [message_kind] and the [count] words at [words] (see the
// TOIT_V2_MESSAGE_* kinds). The words are only read before the first GC
// point. 0 on failure.
uword toit_v2_allocate_exception(void* process, uword value, uword message_kind,
                                 const uword* words, uword count);
// MAY GC. Allocates an array of [length] elements, all [filler]. 0 on failure.
uword toit_v2_allocate_array(void* process, uword length, uword filler);
// MAY GC. Replaces the current task's stack by one with at least [needed]
// free words between the frames and the object stack.
uword toit_v2_grow_stack(void* process, uword needed);
// Allocation for the Rust primitives. Never GCs: 0 when the heap is full
// (the Rust primitive then reports that it needs a GC and the core calls the
// C++ primitive, which collects and retries). Each allocates one object of
// the program's builtin class.
uword toit_v2_try_allocate_large_integer(void* process, int64 value);
uword toit_v2_try_allocate_double(void* process, uint64 bits);
// [length] <= Array::ARRAYLET_SIZE; every element [filler].
uword toit_v2_try_allocate_array(void* process, uword length, uword filler);
// Uninitialized bytes (Process::allocate_string).
uword toit_v2_try_allocate_string(void* process, uword length);
// Zeroed bytes (Process::allocate_byte_array).
uword toit_v2_try_allocate_byte_array(void* process, uword length);
// MAY GC. Calls the C++ primitive (module, index) of the process' policy,
// whose arguments start at object-stack position [first_argument] (counted
// from the bottom), as the C++ interpreter calls it: the entry with a pointer
// to the first argument; the GC-and-retry protocol only when it fails with
// an allocation failure (out of line). TOIT_V2_PRIMITIVE_ABSENT, without
// calling anything, if the policy has no such primitive or its arity is not
// [arity]. May switch the current task (task_transfer). The core compares
// the heap's epoch (toit_v2_context::epoch) around the call: unchanged, no
// object moved and the current stack is the same (TRUSTED.md, "Epoch").
uword toit_v2_primitive(void* process, uword module, uword index, uword arity,
                        uword first_argument, uword* result);
void toit_v2_report(void* process, uword kind, uword bci, uword detail);
// Nonzero if the core should report every instruction (TOIT_V2_REPORT_TRACE),
// for -Xtrace of the debug VM.
uword toit_v2_tracing(void* process);

}  // extern "C"

namespace toit {

class Object;

// Fills [out] with the tables of [program] and its method [table] as the
// core executes them, with [globals] as the global variables (the
// process' globals for a run, the program's initial values for the
// verifier). The one place that describes a program to Rust: the core and
// the verifier (verifier_v2.h) see the same tables.
void v2_program_tables(Program* program, const V2MethodTable* table, Object** globals,
                       toit_v2_program* out);

}  // namespace toit
