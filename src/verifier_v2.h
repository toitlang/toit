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

// The structural verifier of format 2 (verified/spec, `check::verify`,
// proven equal to the specification's `accepts`), linked from Rust
// (verified/vmverify). It reads the program from the tables the verified
// core executes (v2_program_tables), not from the snapshot bytes: one
// description of the program for both. See verified/vmverify/README.md.

#include "top.h"

namespace toit {

class Program;
class V2MethodTable;

class V2Verifier {
 public:
  // Whether the verifier is linked (builds with TOIT_VERIFIED_CORE). Without
  // it every format-2 program is rejected.
  static bool is_available();

  // Verifies [program] with its decoded method [table] (the one the
  // program's process group will run). [trusted] selects the rules of
  // trusted programs (HALT 2 and 3 allowed). On rejection the reason is
  // printed to stderr. With TOIT_VERIFY_TIME=1 the cost is printed to
  // stderr too.
  static bool verify(Program* program, const V2MethodTable* table, bool trusted);

  // As above, with a method table decoded for the call.
  static bool verify(Program* program, bool trusted);

  // Test support (tests/differential.py): writes the canonical form of the
  // abstract program the verifier builds from VM memory to [path].
  static bool write_canonical(Program* program, const V2MethodTable* table, const char* path);
};

}  // namespace toit

extern "C" {

struct toit_v2_program;

// Must match `VerifyInput` in verified/vmverify/src/ffi.rs (checked by
// verified/layout_check.cc).
struct toit_vmverify_input {
  const toit_v2_program* program;   // Globals: the program's initial values.
  const uint32* prim_counts;        // Per module: the number of primitives.
  uword prim_module_count;
  const uint8* prim_arities;        // All arities, module by module.
  uword prim_arities_length;
  uword trusted;
};

static const int TOIT_VMVERIFY_MESSAGE_SIZE = 200;

// Must match `VerifyResult` in verified/vmverify/src/ffi.rs.
struct toit_vmverify_result {
  uword code;                       // TOIT_VMVERIFY_*.
  word method;                      // Rejected method index, or -1.
  word offset;                      // Offset from the method's entry, or -1.
  uword objects;                    // Program-heap objects reachable.
  uint64 convert_ns;
  uint64 heap_ns;
  uint64 infer_ns;
  uint64 check_ns;
  uword peak_bytes;                 // Rust heap high-water mark of the call.
  char message[TOIT_VMVERIFY_MESSAGE_SIZE];
};

static const uword TOIT_VMVERIFY_ACCEPTED = 0;
static const uword TOIT_VMVERIFY_MALFORMED = 1;  // VM memory not convertible.
static const uword TOIT_VMVERIFY_HEAP = 2;       // Loader contract (heap).
static const uword TOIT_VMVERIFY_TABLES = 3;     // wf_program2, tables_ok.
static const uword TOIT_VMVERIFY_METHOD = 4;     // method_ok.
static const uword TOIT_VMVERIFY_INTERNAL = 5;   // The verifier failed.

#ifdef TOIT_VERIFIED_CORE
uword toit_vmverify_verify(const toit_vmverify_input* input, toit_vmverify_result* result);
uword toit_vmverify_canonical(const toit_vmverify_input* input, const char* path);
uword toit_vmverify_layout_count();
bool toit_vmverify_layout_entry(uword i, const char** name, uword* value);
word toit_vmverify_generated_arity(uword module, uword index);
#endif

}  // extern "C"
