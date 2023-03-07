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
#include "../process_group.h"
#include "../scheduler.h"

namespace toit {

MODULE_IMPLEMENTATION(snapshot, MODULE_SNAPSHOT)

PRIMITIVE(launch) {
  ARGS(Blob, bytes, int, gid, Blob, program_id, Object, arguments);
  if (program_id.length() != 16) OUT_OF_BOUNDS;

  unsigned size = 0;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(arguments)) WRONG_TYPE;
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
  Program* program = image.program();
  ProcessGroup* process_group = ProcessGroup::create(gid, program, image.memory());
  ASSERT(process_group);  // Allocations only fail on devices.

  initial_memory_manager.global_variables = program->global_variables.copy();
  ASSERT(initial_memory_manager.global_variables);

  // We don't use snapshots on devices so we assume malloc/new cannot fail.
  int pid = VM::current()->scheduler()->run_program(
      program,
      &encoder,                 // Takes over the encoder.
      process_group,
      &initial_memory_manager); // Takes over the initial_memory_manager.
  ASSERT(pid != Scheduler::INVALID_PROCESS_ID);
  return Smi::from(pid);
}

} // namespace toit

#endif // ndef TOIT_FREERTOS
