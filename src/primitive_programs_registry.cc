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

#ifdef TOIT_FREERTOS
extern "C" uword toit_image_table;
#endif

namespace toit {

MODULE_IMPLEMENTATION(programs_registry, MODULE_PROGRAMS_REGISTRY)

PRIMITIVE(next_group_id) {
  int group_id = VM::current()->scheduler()->next_group_id();
  return Smi::from(group_id);
}

PRIMITIVE(spawn) {
  ARGS(int, offset, int, size, int, group_id, Object, arguments);

  FlashAllocation* allocation = static_cast<FlashAllocation*>(FlashRegistry::memory(offset, size));
  if (allocation->type() != PROGRAM_TYPE) INVALID_ARGUMENT;

  Program* program = static_cast<Program*>(allocation);
  if (!program->is_valid(offset, OS::image_uuid())) OUT_OF_BOUNDS;

  int length = 0;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(arguments)) WRONG_TYPE;
    length = size_encoder.size();
  }

  uint8* buffer = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    buffer = unvoid_cast<uint8*>(malloc(length));
    if (buffer == null) MALLOC_FAILED;
  }

  MessageEncoder encoder(process, buffer);
  if (!encoder.encode(arguments)) {
    encoder.free_copied();
    free(buffer);
    if (encoder.malloc_failed()) MALLOC_FAILED;
    OTHER_ERROR;
  }

  InitialMemoryManager manager;
  if (!manager.allocate()) ALLOCATION_FAILED;

  ProcessGroup* process_group = ProcessGroup::create(group_id, program);
  if (!process_group) MALLOC_FAILED;

  int pid = VM::current()->scheduler()->run_program(program, buffer, process_group, manager.initial_chunk);
  if (pid == Scheduler::INVALID_PROCESS_ID) {
    delete process_group;
    MALLOC_FAILED;
  }
  manager.dont_auto_free();
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

PRIMITIVE(bundled_images) {
#ifdef TOIT_FREERTOS
  const uword* table = &toit_image_table;
  int length = table[0];

  Array* result = process->object_heap()->allocate_array(length * 2, Smi::from(0));
  if (!result) ALLOCATION_FAILED;
  for (int i = 0; i < length; i++) {
    // We store the distance from the start of the table to the image
    // because it naturally fits as a smi even if the virtual addresses
    // involved are large. We tag the entry so we can tell the difference
    // between flash offsets in the data/programs partition and offsets
    // of images bundled with the VM.
    uword diff = table[1 + i * 2] - reinterpret_cast<uword>(table);
    ASSERT(Utils::is_aligned(diff, 4));
    result->at_put(i * 2, Smi::from(diff + 1));
    result->at_put(i * 2 + 1, Smi::from(table[1 + i * 2 + 1]));
  }
  return result;
#else
  return process->program()->empty_array();
#endif
}

} // namespace toit
