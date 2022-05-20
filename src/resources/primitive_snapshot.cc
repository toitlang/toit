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
  ARGS(Blob, bytes, int, gid, Blob, program_id);
  if (program_id.length() != 16) OUT_OF_BOUNDS;

  InitialMemoryManager manager;
  bool ok = manager.allocate();
  USE(ok);
  ASSERT(ok);

  Snapshot snapshot(bytes.address(), bytes.length());
  auto image = snapshot.read_image(program_id.address());
  Program* program = image.program();
  ProcessGroup* process_group = ProcessGroup::create(gid, program, image.memory());
  ASSERT(process_group);  // Allocations only fail on devices.

  // We don't use snapshots on devices so we assume malloc/new cannot fail.
  int pid = VM::current()->scheduler()->run_program(
      program,
      process->args(),
      process_group,
      manager.initial_chunk);
  ASSERT(pid != Scheduler::INVALID_PROCESS_ID);
  manager.dont_auto_free();
  return Smi::from(pid);
}


} // namespace toit

#endif // ndef TOIT_FREERTOS
