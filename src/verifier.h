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

#include "top.h"

namespace toit {

class Program;
class PrimitivePolicy;

// Statistics collected by the verifier. All counts refer to the last
// verification pass (the verifier may run several passes to infer which
// parameters must hold blocks).
struct VerifierStats {
  int passes = 0;
  int methods = 0;            // Distinct methods verified (normal, blocks, lambdas).
  int blocks = 0;
  int lambdas = 0;
  int instructions = 0;       // Reachable instructions.
  int bytes = 0;              // Bytes covered by reachable instructions.
  int method_entries = 0;     // Entries in the interpreter's method entry table.

  // Field access sites and how their receiver was justified. These are
  // diagnostics only: the receivers of field accesses are not part of the
  // structural verification (see TOIT_CHECKED_FIELD_ACCESS).
  int field_sites = 0;
  int field_sites_this = 0;       // Receiver is `this` of a virtual-only method (dispatch witness).
  int field_sites_alloc = 0;      // Receiver is the result of ALLOCATE in the same method.
  int field_sites_range = 0;      // Receiver has a class-check range (header witness or as-check).
  int field_sites_unproven = 0;

  // Static calls to instance methods whose header declares a receiver class range.
  int static_instance_calls = 0;
  int static_instance_calls_proven = 0;

  // Places where the interpreter checks a method id read from the heap at run time.
  int heap_method_id_sites = 0;  // INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL.
  int primitive_sites = 0;
  int distinct_primitives = 0;
  int synthetic_terminators = 0;  // LOAD_NULL; THROW sequences (compiler-inserted terminators).
  int max_states = 0;             // Largest number of per-bci states kept for one method.
  int max_frame_slots = 0;        // Largest frame (max height + arity) seen.
  int max_block_depth = 0;
  int heap_objects = 0;           // Objects in the program heap.
  int heap_bytes = 0;
  int heap_references = 0;        // Pointer fields checked to refer to a program heap object.

  int errors = 0;
  int warnings = 0;
  int64 time_us = 0;
};

struct VerifierOptions {
  // 0: errors only; 1: summary; 2: also warnings; 3: also roots.
  int verbosity = 0;
  // Untrusted programs may not use the HALT codes that terminate the whole
  // VM (2: deep sleep, 3: reset).
  bool untrusted = true;
  // Report unproven field receivers and static instance call receivers as
  // errors instead of warnings.
  bool strict = false;
  // Print the set of primitives the program references.
  bool print_primitives = false;
};

// Structural bytecode verifier.
//
// Checks that a program cannot break the invariants the interpreter relies
// on: every reachable instruction decodes, stack heights and frame accesses
// are consistent, block references and try links are only produced and used
// in the shapes the compiler emits, branch targets, table indexes and
// selectors are in bounds, and the program heap and tables are well-formed.
// It does not prove the receivers of field accesses (the interpreter checks
// those at run time with TOIT_CHECKED_FIELD_ACCESS) and it does not check
// method ids read from the heap (the interpreter checks those against its
// method entry table).
class Verifier {
 public:
  // Verifies the bytecodes, the tables and the program heap of the given
  // program. Returns true if the program is accepted. Diagnostics are printed
  // to stderr.
  static bool verify(Program* program, VerifierStats* stats, const VerifierOptions& options);

  // Whether trusted programs should be verified when they are loaded:
  // -Xverify or the TOIT_VERIFY environment variable.
  static bool is_enabled();

  // Verifies the program if verification is enabled. Returns false if the
  // program is rejected (the errors have been printed).
  // 'untrusted' selects the rules for untrusted programs (see VerifierOptions).
  static bool verify_if_enabled(Program* program, bool untrusted);

  // Install-time verification of a program that is about to run in a new
  // process group with the given policy. Programs launched with the
  // untrusted policy are always verified, with the untrusted rules,
  // independent of -Xverify/TOIT_VERIFY. Other programs are verified with
  // the trusted rules only if verification is enabled. Returns false if the
  // program must not run (the errors have been printed). Builds without the
  // verifier (devices) refuse every untrusted program.
  static bool verify_for_policy(Program* program, const PrimitivePolicy* policy);

  // Testing hook: replaces the program's bytecodes with a writable copy.
  static void set_bytecodes_for_testing(Program* program, uint8* bytes, int length);
  // Testing hook: a buffer of bytecodes-length bytes that receives 1 for
  // every reachable instruction start and 2 for its operand bytes.
  static void set_coverage_for_testing(uint8* coverage);
};

} // namespace toit
