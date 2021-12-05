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
  ARGS(Blob, bytes, int, from, int, to, bool, pass_args);

  Block* initial_block = VM::current()->heap_memory()->allocate_initial_block();
  if (!initial_block) ALLOCATION_FAILED;

  if (!(0 <= from && from <= to && to <= bytes.length())) {
    INVALID_ARGUMENT;
  }
  Snapshot snapshot(&bytes.address()[from], to - from);
  auto image = snapshot.read_image();
  int group_id = VM::current()->scheduler()->next_group_id();
  ProcessGroup* process_group = ProcessGroup::create(group_id);
  if (process_group == NULL) {
    VM::current()->heap_memory()->free_unused_block(initial_block);
    MALLOC_FAILED;
  }

  int pid = pass_args
     ? VM::current()->scheduler()->run_program(image.program(), process->args(), process_group, initial_block)
     : VM::current()->scheduler()->run_program(image.program(), {}, process_group, initial_block);
  // We don't use snapshots on devices so we assume malloc/new cannot fail.
  ASSERT(pid != Scheduler::INVALID_PROCESS_ID);
  return Smi::from(pid);
}


} // namespace toit

#endif // TOIT_LINUX
