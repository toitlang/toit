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

// A decoded entry of the method table: method `i` is the `i`-th method in
// the bytecodes. The table itself is a 4-byte record per method (format
// note 21, V2MethodTable): the entry and the arity; the rest is read from
// the method header, which ends at the entry. This struct is only a value:
// the core decodes the same way (`VMethod`, verified/spec/src/v2/vprog.rs).
struct V2Method {
  uint32 entry;       // Absolute bci of the first instruction.
  uint32 end_;        // The body ends here: the next method's header.
  uint16 selector;    // Selector offset, 0xffff for none.
  uint16 aux;         // Captured count (lambda) or field index (accessor).
  uint16 recv_start;  // Receiver class-id range, 0xffff for none.
  uint16 recv_end;
  uint8 arity;
  uint8 kind;         // 0 method, 1 field accessor, 2 lambda, 3 block.

  word end() const { return static_cast<word>(end_); }
};

static const int V2_KIND_METHOD = 0;
static const int V2_KIND_FIELD_ACCESSOR = 1;
static const int V2_KIND_LAMBDA = 2;
static const int V2_KIND_BLOCK = 3;
static const int V2_NO_VALUE = 0xffff;
// A method record (format note 21): the entry in the high 24 bits, the
// arity in the low 8.
static const int V2_RECORD_ENTRY_SHIFT = 8;
static const uint32 V2_RECORD_ARITY_MASK = 0xff;
// The kind byte of a method header, the byte before the entry: the kind
// and, for a method, that its receiver range is one class or none.
static const int V2_KIND_MASK = 0x3;
static const int V2_KIND_SINGLE = 1 << 2;
// How far before the entry the fields of a header start (u16, little
// endian; format note 21). The distances are odd and the entries of all
// but blocks are odd: in the 2-byte aligned bytecodes every field is
// aligned.
static const int V2_SELECTOR_BACK = 3;
static const int V2_RECV_START_BACK = 5;
static const int V2_RECV_END_BACK = 7;
static const int V2_ACCESSOR_AUX_BACK = 9;
static const int V2_LAMBDA_AUX_BACK = 3;
// Format-2 bytecodes are shorter than this (entries have 24 bits).
static const int V2_MAX_BYTECODES = 0x1000000;
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

// The method table of a format-2 program, owned by its process group
// (format note 21): one 4-byte record per method, the entry in the high 24
// bits and the arity in the low 8, in the program's table literal. The
// rest of a method's description (kind, selector, receiver range, aux) is
// its header, which ends at the entry, every field at a fixed distance
// from it (u16 little endian; 0xffff for no selector or no receiver):
//   method:    [recv_end, unless SINGLE] recv_start selector kind-byte
//   accessor:  aux recv_end recv_start selector kind-byte
//   lambda:    aux kind-byte
//   block:     kind-byte
// A body ends at the next method's header (the last one at the end of the
// bytecodes). The decoding is the spec's (`vdecode`,
// verified/spec/src/v2/vprog.rs), which the core and the verifier use on
// the same records and headers. The loader (compute) checks that every
// header lies inside the bytecodes before its entry (`table_ok`, which
// the core assumes), that the methods follow each other from the tag on,
// and the canonical form of the headers; the structural verifier
// (verifier_v2.h) checks the program, on this table, before an untrusted
// program runs.
class V2MethodTable {
 public:
  ~V2MethodTable();

  // The method table of [program], from its table literal. Returns null
  // (and prints the reason to stderr) if the literal is missing or
  // malformed or the allocation fails; sets [*out_of_memory] (if given)
  // in the latter case.
  static V2MethodTable* compute(Program* program, bool* out_of_memory = null);

  // The method table literal: the compiler appends the table as the
  // program's last literal, a byte array
  //   u32 marker "TMT2"   u32 count   u32 bytecodes length   u32 0
  //   count u32 records (little endian)
  // so that a program in flash (an image on a device) needs no table in
  // RAM. The literal is an ordinary byte array to everything else (no
  // bytecode refers to it). There is no table without it: the headers do
  // not say where a body ends.
  static const uint32 TABLE_LITERAL_MARKER = 0x32544d54;  // "TMT2".
  static const int TABLE_LITERAL_HEADER_SIZE = 16;

  // The literal's bytes for [count] records and bytecodes of the given
  // length. Returns null if the allocation fails; the caller owns the
  // malloc'ed result.
  static uint8* encode_table_literal(const uint32* records, word count, word bytecodes_length, word* length);

  // The number of header bytes the kind byte announces (itself included).
  static int header_size(int kind_byte) {
    switch (kind_byte & V2_KIND_MASK) {
      case V2_KIND_BLOCK: return 1;
      case V2_KIND_LAMBDA: return 3;
      case V2_KIND_FIELD_ACCESSOR: return 9;
      default: return (kind_byte & V2_KIND_SINGLE) != 0 ? 5 : 7;
    }
  }

  // Whether the table uses the program's table literal (no RAM copy).
  bool in_literal() const { return !owned_; }

  const uint32* records() const { return records_; }
  word length() const { return length_; }

  // The method index of the given entry point, or -1.
  word entry_method(Program* program, int entry_point_index) const;

  bool is_valid(word index) const { return 0 <= index && index < length_; }

  // The absolute bci of the entry of a valid method.
  word entry_of(word index) const { return records_[index] >> V2_RECORD_ENTRY_SHIFT; }

  // The absolute bci of the header of a valid method (methods follow each
  // other, the first one after the tag). Format-2 method ids in the debug
  // information (tools/snapshot.toit) are header positions.
  word header_of(word index) const {
    word entry = entry_of(index);
    return entry - header_size(bytecodes_[entry - 1]);
  }

  // The index of the method whose body starts at [entry], or -1.
  word index_of_entry(word entry) const;

  // The decoded method (format note 21).
  V2Method at(word index) const;

  // The launch-time verifier (V2Verifier::verify, verified/vmverify)
  // accepted the program on exactly this table: 0 not verified, 1 under
  // the untrusted rules and the untrusted policy's primitive table, 2 under
  // the trusted rules and the trusted policy's table
  // (PrimitivePolicy::verifier_arities). Set only by the verifier's accept
  // path; the verified run loop of the core runs only for a table it
  // accepted (Interpreter::run_v2, TOIT_V2_ACCEPTED).
  uword verified() const { return verified_; }
  void mark_verified(bool trusted) { verified_ = trusted ? 2 : 1; }

  // Whether a process with this table runs on the verified loop: accepted
  // for the process' own policy. The verdict is bound to the policy whose
  // primitive table it was computed with: a verdict for one policy is never
  // used for a process of another.
  bool runs_verified(bool untrusted) const {
    return verified_ == (untrusted ? 1u : 2u);
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
  // Called after all records have passed validation. Borrows the literal
  // when aligned. Sets the optional failure flag only on allocation failure.
  static V2MethodTable* install(const uint8* records, uword count, const uint8* bytes,
                                word length, bool* out_of_memory);
  V2MethodTable(const uint32* records, word length, const uint8* bytecodes, word bytecodes_length, bool owned)
      : records_(records), length_(length), bytecodes_(bytecodes), bytecodes_length_(bytecodes_length),
        owned_(owned) {}

  const uint32* const records_;
  const word length_;
  const uint8* const bytecodes_;
  const word bytecodes_length_;
  // Whether records_ is malloc'ed (a copy of a misaligned literal; else it
  // is the program's table literal).
  const bool owned_;
  uword verified_ = 0;
};

}  // namespace toit

extern "C" {

// The program tables, as the core sees them. Must match `ProgramTables` in
// verified/core/src/ffi.rs (checked by verified/layout_check.cc).
struct toit_v2_program {
  const uint8* bytecodes;
  uword bytecodes_length;
  const uint32* methods;            // The method records (format note 21).
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
  // PrimitivePolicy::verifier_arities of the process' policy, the table its
  // verdict was computed with: module by module (policy_counts[m] entries
  // of module m from policy_starts[m] on, policy_modules modules), the
  // arity of every primitive the policy allows, VERIFIER_DENIED for the
  // others. The core runs a primitive (its Rust port or toit_v2_primitive)
  // only if the table allows it, and completes a PRIMITIVE of a denied one
  // itself (PERMISSION_DENIED).
  const uint8* policy_arities;
  uword policy_arities_length;
  const uint32* policy_counts;
  const uint32* policy_starts;
  uword policy_modules;
  // ObjectHeap::v2_epoch_address of the process: the core compares it around
  // C++ primitive calls (toit_v2_primitive).
  const uword* epoch;
  // The unchecked mode of trusted programs: the core does not check field
  // accesses (verified/core/EXPERIMENT-trusted.md). TRUSTED: never set for
  // an untrusted process.
  uword unchecked;
  // ObjectHeap::v2_new_space_top_address and v2_new_space_limit_address of
  // the process. The core allocates
  // instances and doubles inline with the new-space fast path
  // (SemiSpace::try_allocate) and calls the allocation helpers below only
  // when it fails (verified/core/TRUSTED.md, "Inline allocation").
  uword* new_space_top;
  const uword* new_space_limit;
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
uword toit_v2_try_allocate_array(void* process, uword length, void* filler);
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
