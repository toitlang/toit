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
#include "flash_registry.h"
#include "scheduler.h"
#include "vm.h"

namespace toit {

MODULE_IMPLEMENTATION(programs_registry, MODULE_PROGRAMS_REGISTRY)

PRIMITIVE(next_group_id) {
  int group_id = VM::current()->scheduler()->next_group_id();
  return Smi::from(group_id);
}

PRIMITIVE(spawn) {
  ARGS(int, offset, int, size, int, group_id);

  FlashAllocation* allocation = static_cast<FlashAllocation*>(FlashRegistry::memory(offset, size));
  if (allocation->type() != PROGRAM_TYPE) INVALID_ARGUMENT;

  Program* program = static_cast<Program*>(allocation);

  if (!program->is_valid(offset, OS::image_uuid())) OUT_OF_BOUNDS;

  ProcessGroup* process_group = ProcessGroup::create(group_id, program);
  if (!process_group) MALLOC_FAILED;

  Chunk* initial_chunk = VM::current()->heap_memory()->allocate_initial_chunk();
  if (!initial_chunk) {
    delete process_group;
    ALLOCATION_FAILED;
  }

  int pid = VM::current()->scheduler()->run_program(program, {}, process_group, initial_chunk);
  if (pid == Scheduler::INVALID_PROCESS_ID) {
    delete process_group;
    VM::current()->heap_memory()->free_unused_chunk(initial_chunk);
    MALLOC_FAILED;
  }
  return Smi::from(pid);
}

PRIMITIVE(is_running) {
  ARGS(int, offset, int, size);
  FlashAllocation* allocation = static_cast<FlashAllocation*>(FlashRegistry::memory(offset, size));
  if (allocation->type() != PROGRAM_TYPE) INVALID_ARGUMENT;

  Program* program = static_cast<Program*>(allocation);
  return BOOL(VM::current()->scheduler()->is_running(program));
}

PRIMITIVE(kill) {
  ARGS(int, offset, int, size);
  FlashAllocation* allocation = static_cast<FlashAllocation*>(FlashRegistry::memory(offset, size));
  if (allocation->type() != PROGRAM_TYPE) INVALID_ARGUMENT;

  Program* program = static_cast<Program*>(allocation);
  return BOOL(VM::current()->scheduler()->kill(program));
}

} // namespace toit
