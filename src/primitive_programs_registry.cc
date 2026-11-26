// Copyright (C) 2018 Toitware ApS.
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

#include "top.h"
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"
#include "process_group.h"
#include "interpreter_v2.h"
#include "verifier_v2.h"
#include "flash_registry.h"
#include "embedded_data.h"
#include "out_of_memory.h"
#include "scheduler.h"
#include "verifier.h"
#include "vm.h"

namespace toit {

MODULE_IMPLEMENTATION(programs_registry, MODULE_PROGRAMS_REGISTRY)

PRIMITIVE(next_group_id) {
  PRIVILEGED;
  int group_id = VM::current()->scheduler()->next_group_id();
  return Smi::from(group_id);
}

PRIMITIVE(spawn) {
  // Starting containers is reserved for the system process. The system
  // process decides the policy of the new process group.
  PRIVILEGED;
  ARGS(int, offset, int, group_id, Object, arguments, Object, policy_description);
  // The system process starts a container for a client (or at boot): an
  // allocation failure fails the start (Container.start) instead of
  // restarting the device. A failed call leaves nothing behind.
  process->object_heap()->set_allocation_failure_recoverable();

  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  if (!allocation) FAIL(OUT_OF_BOUNDS);
  if (allocation->type() != FLASH_ALLOCATION_TYPE_PROGRAM) FAIL(INVALID_ARGUMENT);
  Program* program = const_cast<Program*>(static_cast<const Program*>(allocation));

  // A container in a format this VM cannot run is refused here, before
  // anything is allocated. Without the check a format-2 container on a
  // format-1 firmware (installed trusted, as Jaguar installs) reached
  // Interpreter::run_v2's FATAL and rebooted the device (found on an
  // ESP32-C6, docs/format2-migration.md "Devices: hardware results"), and a
  // format-1 container on a firmware without the C++ interpreter failed
  // with a misleading MALLOC_FAILED.
#ifndef TOIT_VERIFIED_CORE
  if (program->is_format2()) {
    String* error = process->allocate_string("FORMAT_1_REQUIRED");
    if (error == null) FAIL(ALLOCATION_FAILED);
    return Error::from(error);
  }
#endif
#ifdef TOIT_NO_CXX_INTERPRETER
  if (!program->is_format2()) {
    String* error = process->allocate_string("FORMAT_2_REQUIRED");
    if (error == null) FAIL(ALLOCATION_FAILED);
    return Error::from(error);
  }
#endif

  // A sandboxed container starts only if the system heap keeps the sandbox
  // heap floor free after what the container needs to start, and not while
  // its program waits for a restart after running out of memory
  // (Process::sandbox_start_allowed). Checked before anything is allocated:
  // a refused start takes no memory.
  if (PrimitivePolicy::describes_untrusted(policy_description) && !Process::sandbox_start_allowed(program->id())) {
    FAIL(QUOTA_EXCEEDED);
  }

  word message_size = 0;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(arguments)) return size_encoder.create_error_object(process);
    message_size = size_encoder.size();
  }

  uint8* buffer = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    buffer = unvoid_cast<uint8*>(malloc(message_size));
    if (buffer == null) FAIL(MALLOC_FAILED);
  }

  MessageEncoder encoder(process, buffer);  // Takes over buffer.
  if (!encoder.encode(arguments)) {
    return encoder.create_error_object(process);
  }

  InitialMemoryManager initial_memory_manager;
  if (inject_system_allocation_failure(process, "spawn") || !initial_memory_manager.allocate()) {
    FAIL(ALLOCATION_FAILED);
  }

  Object* policy_error = null;
  const PrimitivePolicy* policy = PrimitivePolicy::from_description(policy_description, process, &policy_error);
  if (policy == null) return policy_error;

  // Programs started as untrusted containers are always verified with the
  // untrusted rules before they run: at install time for images flagged
  // untrusted (the verdict is in the allocation, see below), else here.
  // Trusted containers from flash keep running unverified.
  // Untrusted containers run on the verified core, which runs format-2
  // programs only: a format-1 untrusted container is refused in every build
  // (never run on the unverified C++ interpreter).
  if (policy->is_untrusted() && !program->is_format2()) {
    PrimitivePolicy::release(policy);
    fprintf(stderr, "untrusted containers must be in bytecode format 2\n");
    String* error = process->allocate_string("FORMAT_2_REQUIRED");
    if (error == null) FAIL(ALLOCATION_FAILED);
    return Error::from(error);
  }
  // Format 2: the method table the group runs, which is the one verified.
  V2MethodTable* v2_methods = null;
  if (program->is_format2()) {
    v2_methods = V2MethodTable::compute(program);
    if (v2_methods == null) {
      // Malformed method headers (the reason is on stderr).
      PrimitivePolicy::release(policy);
      String* error = process->allocate_string("INVALID_SNAPSHOT");
      if (error == null) FAIL(ALLOCATION_FAILED);
      return Error::from(error);
    }
  }
  if (policy->is_untrusted()) {
    // The install-time verdict (flash_allocation.h): the allocation is
    // valid, so its checksum still covers exactly the bytes that were
    // verified, and the verdict is of this VM's verification epoch (a
    // verdict of another epoch, recorded by a firmware with other
    // install-time checks, is no verdict). An image flagged untrusted
    // without a verdict never starts; it stays installed until it is
    // reinstalled or removed. Images without the flag that are started
    // untrusted (the caller's choice) are verified now; the host remembers
    // that verdict until the allocation is written again
    // (FlashRegistry::is_verified).
    bool recorded = program->is_format2() && allocation->program_verified();
    if (!recorded && allocation->program_untrusted() && program->is_format2()) {
      delete v2_methods;
      PrimitivePolicy::release(policy);
      if (allocation->program_has_verdict_bit()) {
        fprintf(stderr, "untrusted image: verdict of verification epoch %08x, not %08x: reinstall it\n",
                static_cast<unsigned>(allocation->program_verdict_epoch()),
                static_cast<unsigned>(FlashAllocation::verification_epoch()));
      } else {
        fprintf(stderr, "untrusted image without an install-time verdict\n");
      }
      String* error = process->allocate_string("VERIFICATION_FAILED");
      if (error == null) FAIL(ALLOCATION_FAILED);
      return Error::from(error);
    }
    bool cached = recorded || (program->is_format2() && FlashRegistry::is_verified(allocation));
    if (!cached && !Verifier::verify_for_policy(program, policy, v2_methods)) {
      delete v2_methods;
      PrimitivePolicy::release(policy);
      String* error = process->allocate_string("VERIFICATION_FAILED");
      if (error == null) FAIL(ALLOCATION_FAILED);
      return Error::from(error);
    }
    if (cached) V2Verifier::accept_recorded(v2_methods);
    if (!cached && program->is_format2()) FlashRegistry::set_verified(allocation);
  }

  // Takes over the policy and the method table, also on failure.
  ProcessGroup* process_group = ProcessGroup::create(group_id, program, null, policy, v2_methods);
  if (!process_group) FAIL(MALLOC_FAILED);

  initial_memory_manager.global_variables = program->global_variables.copy();
  if (!initial_memory_manager.global_variables) {
    delete process_group;
    FAIL(MALLOC_FAILED);
  }

  // Takes over the encoder and the initial_memory_manager.
  int pid = VM::current()->scheduler()->run_program(program, &encoder, process_group, &initial_memory_manager);
  if (pid < 0) {
    delete process_group;
    if (pid == Scheduler::QUOTA_EXCEEDED_PROCESS_ID) FAIL(QUOTA_EXCEEDED);
    FAIL(MALLOC_FAILED);
  }
  return Smi::from(pid);
}

PRIMITIVE(is_running) {
  ARGS(int, offset);
  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  if (!allocation) FAIL(OUT_OF_BOUNDS);
  if (allocation->type() != FLASH_ALLOCATION_TYPE_PROGRAM) FAIL(INVALID_ARGUMENT);
  const Program* program = static_cast<const Program*>(allocation);
  return BOOL(VM::current()->scheduler()->is_running(program));
}

PRIMITIVE(kill) {
  PRIVILEGED;
  ARGS(int, offset);
  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  if (!allocation) FAIL(OUT_OF_BOUNDS);
  if (allocation->type() != FLASH_ALLOCATION_TYPE_PROGRAM) FAIL(INVALID_ARGUMENT);
  const Program* program = static_cast<const Program*>(allocation);
  return BOOL(VM::current()->scheduler()->kill(program));
}

PRIMITIVE(bundled_images) {
#ifdef TOIT_FREERTOS
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  word length = extension->images();
  Array* result = process->object_heap()->allocate_array(length * 2, Smi::from(0));
  if (!result) FAIL(ALLOCATION_FAILED);
  for (word i = 0; i < length; i++) {
    // We store the distance from the start of the header to the image
    // because it naturally fits as a smi even if the virtual addresses
    // involved are large. We tag the entry so we can tell the difference
    // between flash offsets in the data/programs partition and offsets
    // of images bundled with the VM.
    EmbeddedImage image = extension->image(i);
    uword offset = extension->offset(image.program);
    ASSERT(Utils::is_aligned(offset, 4));
    result->at_put(i * 2, Smi::from(offset + 1));
    result->at_put(i * 2 + 1, Smi::from(image.size));
  }
  return result;
#else
  return process->program()->empty_array();
#endif
}

PRIMITIVE(assets) {
  Program* program = process->program();
  word size;
  uint8* bytes;
  Object* result = null;
  if (program->program_assets_size(&bytes, &size) == 0) {
    result = process->object_heap()->allocate_internal_byte_array(0);
  } else {
    result = process->object_heap()->allocate_external_byte_array(size, bytes, false, false);
  }
  if (!result) FAIL(ALLOCATION_FAILED);
  return result;
}

PRIMITIVE(config) {
  PRIVILEGED;
#if defined(TOIT_ESP32) || defined(TOIT_EC618)
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  List<uint8> config = extension->config();
  Object* result = config.is_empty()
      ? process->object_heap()->allocate_internal_byte_array(0)
      : process->object_heap()->allocate_external_byte_array(config.length(), config.data(), false, false);
#else
  Object* result = process->object_heap()->allocate_internal_byte_array(0);
#endif
  if (!result) FAIL(ALLOCATION_FAILED);
  return result;
}

} // namespace toit
