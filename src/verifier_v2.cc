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
#include "flash_allocation.h"
#include "flash_registry.h"
#include "flags.h"
#include "os.h"
#include "process.h"

namespace toit {

const char* const V2Verifier::OUT_OF_MEMORY = "OUT_OF_MEMORY";

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

const char* V2Verifier::install_verdict(const void* memory, word program_size, uint8* metadata,
                                        const uint8* certificate, word certificate_length,
                                        Process* process) {
  metadata[0] &= ~FlashAllocation::Header::FLAGS_PROGRAM_VERIFIED_MASK;
  if ((metadata[0] & FlashAllocation::Header::FLAGS_PROGRAM_UNTRUSTED_MASK) == 0) return null;
  FlashRegistry::flush();
  Program* program = reinterpret_cast<Program*>(const_cast<void*>(memory));
  bool no_verdict = false;
  const char* error = verify_installed(program, program_size, &no_verdict, certificate, certificate_length,
                                       process);
  if (error != null) return error;
  if (!no_verdict) metadata[0] |= FlashAllocation::Header::FLAGS_PROGRAM_VERIFIED_MASK;
  return null;
}

bool V2Verifier::infers() {
#ifdef TOIT_VERIFIED_CORE_INFER
  if (Flags::require_certificate) return false;
  const char* env = getenv("TOIT_REQUIRE_CERTIFICATE");
  return env == null || strcmp(env, "1") != 0;
#else
  return false;
#endif
}

#ifdef TOIT_VERIFIED_CORE

static void v2_input(Program* program, const V2MethodTable* table, bool trusted,
                     toit_v2_program* tables, toit_vmverify_input* input, word program_size = -1,
                     const uint8* certificate = null, word certificate_length = 0) {
  // The program's initial global values: the process' globals start as a
  // copy of them.
  v2_program_tables(program, table, program->global_variables.array(), tables);
  // At install time the allocation header (which holds the size) is not
  // written yet.
  if (program_size >= 0) tables->program_heap_size = program_size;
  input->program = tables;
  input->prim_counts = v2_prim_counts;
  input->prim_module_count = ARRAY_SIZE(v2_prim_counts);
  input->prim_arities = v2_prim_arities;
  input->prim_arities_length = ARRAY_SIZE(v2_prim_arities);
  input->trusted = trusted ? 1 : 0;
  input->certificate = certificate;
  input->certificate_length = certificate == null ? 0 : certificate_length;
  input->progress = null;
  input->progress_context = null;
}

// The context of the verifier's progress callback.
struct V2Progress {
  Process* process;  // Or null.
  uword calls;
};

// The verifier's progress callback (toit_vmverify_input::progress), called
// before each method: the verification runs inside one primitive of the
// process, which the scheduler's dead-lock check would otherwise kill
// after PROCESS_MAX_RUN_TIME_US (scheduler.cc). Touches nothing the
// verifier reads.
static void v2_progress(void* context, uword method) {
  V2Progress* progress = reinterpret_cast<V2Progress*>(context);
  progress->calls++;
  if (progress->process != null) progress->process->note_progress(OS::get_monotonic_time());
}

static const char* v2_code_name(uword code) {
  switch (code) {
    case TOIT_VMVERIFY_MALFORMED: return "malformed program memory";
    case TOIT_VMVERIFY_HEAP: return "program heap";
    case TOIT_VMVERIFY_TABLES: return "program tables";
    case TOIT_VMVERIFY_METHOD: return "method";
    case TOIT_VMVERIFY_INTERNAL: return "verifier failure";
    case TOIT_VMVERIFY_CERTIFICATE: return "shipped certificate";
    case TOIT_VMVERIFY_NO_CERTIFICATE: return "no certificate";
    case TOIT_VMVERIFY_OUT_OF_MEMORY: return "out of memory";
    default: return "unknown";
  }
}

bool V2Verifier::is_available() { return true; }

// The panic handler of the Rust library on devices (no_std, panic = abort:
// verified/vmverify/src/device.rs). Hosts catch the verifier's panics in
// Rust instead and never call this.
extern "C" void toit_vmverify_panic(const uint8* file, uword length) {
  FATAL("Rust panic in %.*s", static_cast<int>(length), reinterpret_cast<const char*>(file));
}

static bool v2_verify(Program* program, const V2MethodTable* table, bool trusted, word program_size,
                      const uint8* certificate, word certificate_length, Process* process,
                      bool* out_of_memory = null);

bool V2Verifier::verify(Program* program, const V2MethodTable* table, bool trusted,
                        const uint8* certificate, word certificate_length) {
  return v2_verify(program, table, trusted, -1, certificate, certificate_length, null);
}

static bool v2_verify(Program* program, const V2MethodTable* table, bool trusted, word program_size,
                      const uint8* certificate, word certificate_length, Process* process,
                      bool* out_of_memory) {
  if (certificate == null && !V2Verifier::infers()) {
    // Devices (and hosts with -Xrequire_certificate): no inference, so no
    // verdict without a shipped certificate. Rejected before the program is
    // converted.
    fprintf(stderr, "verifier: %sprogram rejected: %s\n", trusted ? "" : "untrusted ",
            v2_code_name(TOIT_VMVERIFY_NO_CERTIFICATE));
    return false;
  }
  toit_v2_program tables;
  toit_vmverify_input input;
  v2_input(program, table, trusted, &tables, &input, program_size, certificate, certificate_length);
  V2Progress progress = { process, 0 };
  input.progress = &v2_progress;
  input.progress_context = &progress;
  toit_vmverify_result result;
  toit_vmverify_verify(&input, &result);
  result.message[TOIT_VMVERIFY_MESSAGE_SIZE - 1] = '\0';
  const char* timing = getenv("TOIT_VERIFY_TIME");
  if (timing != null && strcmp(timing, "1") == 0) {
    fprintf(stderr,
            "verifier: %s%s, %" PRIdPTR " methods, %" PRIuPTR " bytecodes, %" PRIuPTR " objects;"
            " convert %.2f ms, heap %.2f ms, infer %.2f ms, check %.2f ms; peak %" PRIuPTR " KB;"
            " progress %" PRIuPTR "%s\n",
            result.code == TOIT_VMVERIFY_ACCEPTED ? "accepted" : "rejected",
            certificate != null ? " (shipped certificate)" : "",
            table->length(), static_cast<uword>(program->bytecodes.length()), result.objects,
            result.convert_ns / 1e6, result.heap_ns / 1e6, result.infer_ns / 1e6,
            result.check_ns / 1e6, result.peak_bytes >> 10,
            progress.calls, process != null ? " (to the scheduler)" : "");
  }
  if (result.code == TOIT_VMVERIFY_ACCEPTED) {
    // The only place that marks a table verified (the core's verified run
    // loop relies on it: Interpreter::run_v2).
    const_cast<V2MethodTable*>(table)->mark_verified(trusted);
    return true;
  }
  if (out_of_memory != null) *out_of_memory = result.code == TOIT_VMVERIFY_OUT_OF_MEMORY;
  const char* kind = trusted ? "" : "untrusted ";
  if (result.method >= 0 && table->is_valid(result.method)) {
    word bci = table->at(result.method).entry + (result.offset >= 0 ? result.offset : 0);
    fprintf(stderr, "verifier: %sprogram rejected: method %" PRIdPTR " at bci %" PRIdPTR " (+%" PRIdPTR "): %s\n",
            kind, result.method, bci, result.offset, result.message);
  } else {
    fprintf(stderr, "verifier: %sprogram rejected: %s: %s\n",
            kind, v2_code_name(result.code), result.message);
  }
  if (!trusted && result.message != null && strstr(result.message, "not in the unchecked mode") != null) {
    // The compiler's default is first-party code with the trusted-only
    // twins (docs/format2-migration.md).
    fprintf(stderr, "verifier: the program was compiled for trusted use; compile it with --untrusted\n");
  }
  return false;
}

const char* V2Verifier::verify_installed(Program* program, word program_size, bool* no_verdict,
                                         const uint8* certificate, word certificate_length,
                                         Process* process) {
  *no_verdict = false;
  if (!program->is_format2()) {
    if (V2MethodTable::untrusted_format1_allowed()) {
      *no_verdict = true;
      return null;
    }
    fprintf(stderr, "untrusted images must be in bytecode format 2 (use -Xuntrusted_format1 to allow format 1)\n");
    return "FORMAT_2_REQUIRED";
  }
  bool out_of_memory = false;
  V2MethodTable* table = V2MethodTable::compute(program, &out_of_memory);
  if (table == null) return out_of_memory ? OUT_OF_MEMORY : "INVALID_SNAPSHOT";
  bool accepted = v2_verify(program, table, false, program_size, certificate, certificate_length, process,
                            &out_of_memory);
  delete table;
  if (accepted) return null;
  return out_of_memory ? OUT_OF_MEMORY : "VERIFICATION_FAILED";
}

void V2Verifier::accept_recorded(const V2MethodTable* table) {
  const_cast<V2MethodTable*>(table)->mark_verified(false);
}

bool V2Verifier::write_canonical(Program* program, const V2MethodTable* table, const char* path) {
  toit_v2_program tables;
  toit_vmverify_input input;
  v2_input(program, table, false, &tables, &input);
  return toit_vmverify_canonical(&input, path) == 0;
}

#ifdef TOIT_VERIFIED_CORE_INFER
// Builds with the inference only (hosts): devices link the verifier without
// it.
bool V2Verifier::certify(Program* program, const V2MethodTable* table, bool trusted,
                         uint8** bytes, word* length) {
  toit_v2_program tables;
  toit_vmverify_input input;
  v2_input(program, table, trusted, &tables, &input);
  uint8* rust_bytes = null;
  uword rust_length = 0;
  uword code = toit_vmverify_certify(&input, &rust_bytes, &rust_length);
  if (code != 0) {
    fprintf(stderr, "certify: %s\n", code == 1
        ? "malformed program memory"
        : "no certificate the verifier accepts (run toit.run --verify for the reason)");
    return false;
  }
  *bytes = unvoid_cast<uint8*>(malloc(rust_length));
  if (*bytes == null) {
    toit_vmverify_free_certificate(rust_bytes, rust_length);
    return false;
  }
  memcpy(*bytes, rust_bytes, rust_length);
  *length = rust_length;
  toit_vmverify_free_certificate(rust_bytes, rust_length);
  return true;
}
#else
bool V2Verifier::certify(Program* program, const V2MethodTable* table, bool trusted,
                         uint8** bytes, word* length) {
  return false;
}
#endif

#else  // !TOIT_VERIFIED_CORE

bool V2Verifier::is_available() { return false; }

bool V2Verifier::verify(Program* program, const V2MethodTable* table, bool trusted,
                        const uint8* certificate, word certificate_length) {
  USE(v2_prim_arities);
  USE(v2_prim_counts);
  fprintf(stderr, "verifier: format-2 programs need the verified core (TOIT_VERIFIED_CORE)\n");
  return false;
}

bool V2Verifier::write_canonical(Program* program, const V2MethodTable* table, const char* path) {
  return false;
}

const char* V2Verifier::verify_installed(Program* program, word program_size, bool* no_verdict,
                                         const uint8* certificate, word certificate_length,
                                         Process* process) {
  *no_verdict = !program->is_format2() && V2MethodTable::untrusted_format1_allowed();
  if (*no_verdict) return null;
  // Without the verifier no untrusted program can be admitted.
  return program->is_format2() ? "VERIFICATION_FAILED" : "FORMAT_2_REQUIRED";
}

void V2Verifier::accept_recorded(const V2MethodTable* table) {
  // Never reached: no allocation gets a verdict without the verifier.
}

bool V2Verifier::certify(Program* program, const V2MethodTable* table, bool trusted,
                         uint8** bytes, word* length) {
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
