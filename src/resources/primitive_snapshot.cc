// Copyright (C) 2020 Toitware ApS.
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

#include "../top.h"

#ifndef TOIT_FREERTOS

#include "../heap.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../os.h"
#include "../vm.h"
#include "../primitive_policy.h"
#include "../process_group.h"
#include "../scheduler.h"
#include "../verifier.h"
#include "../interpreter_v2.h"

namespace toit {

MODULE_IMPLEMENTATION(snapshot, MODULE_SNAPSHOT)

// Returns an error with the given text, so the system process can tell a
// refused program apart from bad arguments.
static Object* launch_error(Process* process, const char* text) {
  String* error = process->allocate_string(text);
  if (error == null) FAIL(ALLOCATION_FAILED);
  return Error::from(error);
}

PRIMITIVE(launch) {
  // Launching a program from bytes is reserved for the system process. The
  // system process decides the policy of the launched program group.
  PRIVILEGED;
  ARGS(Blob, bytes, int, gid, Blob, program_id, Object, arguments, Object, policy_description,
       Object, certificate_object);
  if (program_id.length() != 16) FAIL(OUT_OF_BOUNDS);
  // The shipped certificate of a format-2 program (verified/spec/format/
  // 18-shipped-certificate.md), or null. Only read during verification.
  Blob certificate;
  bool has_certificate = false;
  if (certificate_object != process->null_object()) {
    if (!certificate_object->byte_content(process->program(), &certificate, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
    has_certificate = true;
  }

  // As for programs_registry.spawn: a sandboxed container starts only with
  // room above the sandbox heap floor (Process::sandbox_start_allowed).
  if (PrimitivePolicy::describes_untrusted(policy_description) &&
      !Process::sandbox_start_allowed(program_id.address())) {
    FAIL(QUOTA_EXCEEDED);
  }

  Object* policy_error = null;
  const PrimitivePolicy* policy = PrimitivePolicy::from_description(policy_description, process, &policy_error);
  if (policy == null) return policy_error;
  // Release an owned policy on the early-failure paths below.
  class PolicyHolder {
   public:
    explicit PolicyHolder(const PrimitivePolicy* policy) : policy_(policy) {}
    ~PolicyHolder() { PrimitivePolicy::release(policy_); }
    const PrimitivePolicy* take() { auto result = policy_; policy_ = null; return result; }
   private:
    const PrimitivePolicy* policy_;
  } policy_holder(policy);

  word size = 0;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(arguments)) FAIL(WRONG_OBJECT_TYPE);
    size = size_encoder.size();
  }

  uint8* buffer = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    buffer = unvoid_cast<uint8*>(malloc(size));
    ASSERT(buffer);  // Allocations only fail on devices.
  }
  MessageEncoder encoder(process, buffer);  // Takes over buffer.
  encoder.encode(arguments);

  InitialMemoryManager initial_memory_manager;
  bool ok = initial_memory_manager.allocate();
  USE(ok);
  ASSERT(ok);

  Snapshot snapshot(bytes.address(), bytes.length());
  auto image = snapshot.read_image(program_id.address());
  if (!image.is_valid()) FAIL(INVALID_ARGUMENT);
  Program* program = image.program();
  // Install-time structural verification of the launched snapshot. Untrusted
  // programs are always verified with the untrusted rules (no HALT 2/3);
  // trusted ones only with -Xverify/TOIT_VERIFY. A rejected program never
  // runs.
  // Untrusted programs run on the verified core: format 2 only, in every
  // build. A verified-core image of another format version runs nowhere
  // (Program::has_stale_v2_tag).
  if (program->has_stale_v2_tag()) {
    fprintf(stderr, "bytecode format TBC%c is not supported by this VM; recompile\n",
            program->stale_v2_tag_digit());
    image.release();
    return launch_error(process, "FORMAT_2_REQUIRED");
  }
  if (policy->is_untrusted() && !program->is_format2()) {
    image.release();
    return launch_error(process, "FORMAT_2_REQUIRED");
  }
  // Format 2: the method table the group runs, which is the one verified.
  V2MethodTable* v2_methods = null;
  if (program->is_format2()) {
    v2_methods = V2MethodTable::compute(program);
    if (v2_methods == null) {
      // Malformed method headers (the reason is on stderr).
      image.release();
      return launch_error(process, "INVALID_SNAPSHOT");
    }
  }
  if (!Verifier::verify_for_policy(program, policy, v2_methods,
                                   has_certificate ? certificate.address() : null,
                                   has_certificate ? certificate.length() : 0)) {
    delete v2_methods;
    image.release();
    return launch_error(process, "VERIFICATION_FAILED");
  }
  // Takes over the method table. Allocations only fail on devices.
  ProcessGroup* process_group = ProcessGroup::create(gid, program, image.memory(), policy_holder.take(), v2_methods);
  if (process_group == null) {
    image.release();
    return launch_error(process, "INVALID_SNAPSHOT");
  }

  initial_memory_manager.global_variables = program->global_variables.copy();
  ASSERT(initial_memory_manager.global_variables);

  int pid = VM::current()->scheduler()->run_program(
      program,
      &encoder,                 // Takes over the encoder.
      process_group,
      &initial_memory_manager); // Takes over the initial_memory_manager.
  if (pid < 0) {
    delete process_group;
    if (pid == Scheduler::QUOTA_EXCEEDED_PROCESS_ID) FAIL(QUOTA_EXCEEDED);
    FAIL(MALLOC_FAILED);
  }
  return Smi::from(pid);
}

} // namespace toit

#endif // ndef TOIT_FREERTOS
