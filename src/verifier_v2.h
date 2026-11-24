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

class Process;
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
  // [certificate] is the shipped certificate of the program (format 2
  // note 18, verified/spec/format/18-shipped-certificate.md), or null:
  // then the verifier infers one (infers()) or rejects the program.
  static bool verify(Program* program, const V2MethodTable* table, bool trusted,
                     const uint8* certificate = null, word certificate_length = 0);

  // As above, with a method table decoded for the call.
  static bool verify(Program* program, bool trusted);

  // Whether a program without a shipped certificate can be verified: the
  // inference is linked (TOIT_VERIFIED_CORE_INFER, hosts) and not switched
  // off with -Xrequire_certificate or TOIT_REQUIRE_CERTIFICATE=1 (which
  // makes a host behave as a device). Devices link no inference: every
  // untrusted format-2 program needs a certificate.
  static bool infers();

  // Install-time verification (Phase 5) of the program (of [program_size]
  // bytes, without assets) of an image flagged untrusted, before its flash
  // allocation is committed, with the image's shipped [certificate] (the
  // trailing block, FlashAllocation::find_certificate_block) or null. Returns null if the verifier
  // accepted the program with the untrusted rules (the caller records the
  // verdict in the allocation: FlashAllocation::program_verified), else
  // the error to fail with (VERIFICATION_FAILED, INVALID_SNAPSHOT or
  // FORMAT_2_REQUIRED). A format-1 program gets no verdict and is not an
  // error when -Xuntrusted_format1 allows it ([*no_verdict] is set).
  // The verification runs inside one primitive of [process] (if not null)
  // and reports its progress to the scheduler before each method
  // (Process::note_progress), so a long verification is not taken for a
  // dead-lock (verified/vmverify/README.md, "Install time").
  static const char* verify_installed(Program* program, word program_size, bool* no_verdict,
                                      const uint8* certificate = null, word certificate_length = 0,
                                      Process* process = null);

  // Null if every table of the program image at [program] of
  // [program_size] bytes (the List and Table fields of the Program, and
  // the method table literal) lies inside the image; else the reason.
  // verify_installed checks it before it reads anything else of the image.
  static const char* image_layout_error(const Program* program, word program_size);

  // Null if the builtin class ids are classes with the tags and at least
  // the fields the C++ VM assumes, and the builtin roots have their kinds
  // (as the format-1 verifier checks); else the reason. The verifier
  // checks it on every program it accepts, after the conversion checked
  // that the roots are objects of the image.
  static const char* builtin_classes_error(Program* program);

  // The install-time verdict for the program image at [memory] of
  // [program_size] bytes (written, its header not yet) with its shipped
  // [certificate] (or null), with the [metadata] its header will get: clears
  // the verdict bit the installer may have set (only the VM sets it), and
  // for an image flagged untrusted verifies the program (verify_installed)
  // and sets the bit if it is accepted. Returns null or the error to fail
  // the commit with. Called by the commit paths (image.writer-commit,
  // flash_registry.allocate) in [process] (see verify_installed).
  //
  // An allocation failure of the method table or the verifier returns
  // OUT_OF_MEMORY (the string "OUT_OF_MEMORY"): the commit primitives then
  // fail once with CROSS_PROCESS_GC, so the interpreter collects every
  // process's garbage (returning free heap pages to the system) and retries
  // the primitive; a second failure is the error (verified/core/PROGRESS.md,
  // "Device builds").
  static const char* const OUT_OF_MEMORY;
  static const char* install_verdict(const void* memory, word program_size, uint8* metadata,
                                     const uint8* certificate = null, word certificate_length = 0,
                                     Process* process = null);

  // Marks [table], decoded from the bytes of an allocation with the
  // install-time verdict, as accepted with the untrusted rules (the verdict
  // and the bytes are bound by the allocation's checksum). Also for the
  // host's verdict cache (FlashRegistry::is_verified).
  static void accept_recorded(const V2MethodTable* table);

  // Test support (verified/tools/vmverify_differential.toit): writes the
  // canonical form of the abstract program the verifier builds from VM
  // memory to [path].
  static bool write_canonical(Program* program, const V2MethodTable* table, const char* path);

  // The toolchain's producer of shipped certificates (hosts): infers the
  // certificate of [program], checks it as the device will, and returns it
  // in [bytes] (malloced; the caller frees it). False if the program has no
  // accepted certificate (the reason is printed).
  static bool certify(Program* program, const V2MethodTable* table, bool trusted,
                      uint8** bytes, word* length);
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
  const uint8* certificate;         // The shipped certificate, or null.
  uword certificate_length;
  // Called with [progress_context] before each method of a shipped
  // certificate is checked, or null. Must not touch the program, its tables
  // or the certificate.
  void (*progress)(void* context, uword method);
  void* progress_context;
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
static const uword TOIT_VMVERIFY_CERTIFICATE = 6;  // Shipped certificate rejected.
static const uword TOIT_VMVERIFY_NO_CERTIFICATE = 7;  // None shipped, none inferred.
static const uword TOIT_VMVERIFY_OUT_OF_MEMORY = 8;   // An allocation of the verifier failed.

#ifdef TOIT_VERIFIED_CORE
uword toit_vmverify_verify(const toit_vmverify_input* input, toit_vmverify_result* result);
uword toit_vmverify_canonical(const toit_vmverify_input* input, const char* path);
uword toit_vmverify_certify(const toit_vmverify_input* input, uint8** bytes, uword* length);
void toit_vmverify_free_certificate(uint8* bytes, uword length);
uword toit_vmverify_layout_count();
bool toit_vmverify_layout_entry(uword i, const char** name, uword* value);
word toit_vmverify_generated_arity(uword module, uword index);
#endif

}  // extern "C"
