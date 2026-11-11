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

#include "verifier_v2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "interpreter_v2.h"
#include "primitive.h"
#include "program.h"

namespace toit {

// The VM's primitive table, from the same declarations the primitives are
// compiled from (primitive.h): the verifier checks every PRIMITIVE
// instruction against these arities.
#define V2_ARITY_ONE(name, arity) arity,
#define V2_MODULE_ARITIES(name, entries) entries(V2_ARITY_ONE)
#define V2_MODULE_COUNT(name, entries) 0 entries(MODULE_PRIMITIVE_COUNT_ONE),
static const uint8 v2_prim_arities[] = { MODULES(V2_MODULE_ARITIES) };
static const uint32 v2_prim_counts[] = { MODULES(V2_MODULE_COUNT) };
#undef V2_ARITY_ONE
#undef V2_MODULE_ARITIES
#undef V2_MODULE_COUNT

#ifdef TOIT_VERIFIED_CORE

static void v2_input(Program* program, const V2MethodTable* table, bool trusted,
                     toit_v2_program* tables, toit_vmverify_input* input) {
  // The program's initial global values: the process' globals start as a
  // copy of them.
  v2_program_tables(program, table, program->global_variables.array(), tables);
  input->program = tables;
  input->prim_counts = v2_prim_counts;
  input->prim_module_count = ARRAY_SIZE(v2_prim_counts);
  input->prim_arities = v2_prim_arities;
  input->prim_arities_length = ARRAY_SIZE(v2_prim_arities);
  input->trusted = trusted ? 1 : 0;
  input->certificate = null;
  input->certificate_length = 0;
}

static const char* v2_code_name(uword code) {
  switch (code) {
    case TOIT_VMVERIFY_MALFORMED: return "malformed program memory";
    case TOIT_VMVERIFY_HEAP: return "program heap";
    case TOIT_VMVERIFY_TABLES: return "program tables";
    case TOIT_VMVERIFY_METHOD: return "method";
    case TOIT_VMVERIFY_INTERNAL: return "verifier failure";
    default: return "unknown";
  }
}

bool V2Verifier::is_available() { return true; }

bool V2Verifier::verify(Program* program, const V2MethodTable* table, bool trusted) {
  toit_v2_program tables;
  toit_vmverify_input input;
  v2_input(program, table, trusted, &tables, &input);
  toit_vmverify_result result;
  toit_vmverify_verify(&input, &result);
  result.message[TOIT_VMVERIFY_MESSAGE_SIZE - 1] = '\0';
  const char* timing = getenv("TOIT_VERIFY_TIME");
  if (timing != null && strcmp(timing, "1") == 0) {
    fprintf(stderr,
            "verifier: %s, %" PRIdPTR " methods, %" PRIuPTR " bytecodes, %" PRIuPTR " objects;"
            " convert %.2f ms, heap %.2f ms, infer %.2f ms, check %.2f ms; peak %" PRIuPTR " KB\n",
            result.code == TOIT_VMVERIFY_ACCEPTED ? "accepted" : "rejected",
            table->length(), static_cast<uword>(program->bytecodes.length()), result.objects,
            result.convert_ns / 1e6, result.heap_ns / 1e6, result.infer_ns / 1e6,
            result.check_ns / 1e6, result.peak_bytes >> 10);
  }
  if (result.code == TOIT_VMVERIFY_ACCEPTED) {
    // The only place that marks a table verified (the core's verified run
    // loop relies on it: Interpreter::run_v2).
    const_cast<V2MethodTable*>(table)->mark_verified(trusted);
    return true;
  }
  const char* kind = trusted ? "" : "untrusted ";
  if (result.method >= 0 && table->is_valid(result.method)) {
    word bci = table->at(result.method).entry + (result.offset >= 0 ? result.offset : 0);
    fprintf(stderr, "verifier: %sprogram rejected: method %" PRIdPTR " at bci %" PRIdPTR " (+%" PRIdPTR "): %s\n",
            kind, result.method, bci, result.offset, result.message);
  } else {
    fprintf(stderr, "verifier: %sprogram rejected: %s: %s\n",
            kind, v2_code_name(result.code), result.message);
  }
  return false;
}

bool V2Verifier::write_canonical(Program* program, const V2MethodTable* table, const char* path) {
  toit_v2_program tables;
  toit_vmverify_input input;
  v2_input(program, table, false, &tables, &input);
  return toit_vmverify_canonical(&input, path) == 0;
}

#else  // !TOIT_VERIFIED_CORE

bool V2Verifier::is_available() { return false; }

bool V2Verifier::verify(Program* program, const V2MethodTable* table, bool trusted) {
  USE(v2_prim_arities);
  USE(v2_prim_counts);
  fprintf(stderr, "verifier: format-2 programs need the verified core (TOIT_VERIFIED_CORE)\n");
  return false;
}

bool V2Verifier::write_canonical(Program* program, const V2MethodTable* table, const char* path) {
  return false;
}

#endif  // TOIT_VERIFIED_CORE

bool V2Verifier::verify(Program* program, bool trusted) {
  V2MethodTable* table = V2MethodTable::compute(program);
  if (table == null) return false;
  bool result = verify(program, table, trusted);
  delete table;
  return result;
}

}  // namespace toit
