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
#include "embedded_data.h"
#include "scheduler.h"
#include "vm.h"

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
  if (!program->is_valid(offset, EmbeddedData::uuid())) OUT_OF_BOUNDS;

  unsigned message_size = 0;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(arguments)) return size_encoder.create_error_object(process);
    message_size = size_encoder.size();
  }

  uint8* buffer = null;
  { HeapTagScope scope(ITERATE_CUSTOM_TAGS + EXTERNAL_BYTE_ARRAY_MALLOC_TAG);
    buffer = unvoid_cast<uint8*>(malloc(message_size));
    if (buffer == null) MALLOC_FAILED;
  }
  AllocationManager free_buffer(process, buffer);

  MessageEncoder encoder(process, buffer);
  if (!encoder.encode(arguments)) {
    return encoder.create_error_object(process);
  }

  InitialMemoryManager manager;
  if (!manager.allocate()) ALLOCATION_FAILED;

  ProcessGroup* process_group = ProcessGroup::create(group_id, program);
  if (!process_group) MALLOC_FAILED;
  AllocationManager free_process_group(process, process_group);

  Object** global_variables = program->global_variables.copy();
  if (!global_variables) MALLOC_FAILED;
  AllocationManager free_global_variables(process, global_variables);

  int pid = VM::current()->scheduler()->run_program(program, buffer, process_group, manager.initial_chunk, global_variables);
  if (pid == Scheduler::INVALID_PROCESS_ID) MALLOC_FAILED;
  manager.dont_auto_free();
  free_buffer.keep_result();
  free_process_group.keep_result();
  free_global_variables.keep_result();
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
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  int length = extension->images();
  Array* result = process->object_heap()->allocate_array(length * 2, Smi::from(0));
  if (!result) ALLOCATION_FAILED;
  for (int i = 0; i < length; i++) {
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
  int size;
  uint8* bytes;
  if (program->assets_size(&bytes, &size) == 0) {
    return process->object_heap()->allocate_internal_byte_array(0);
  }
  return process->object_heap()->allocate_external_byte_array(size, bytes, false, false);
}

PRIMITIVE(config) {
  PRIVILEGED;
#ifdef TOIT_FREERTOS
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  List<uint8> config = extension->config();
  return config.is_empty()
      ? process->object_heap()->allocate_internal_byte_array(0)
      : process->object_heap()->allocate_external_byte_array(config.length(), config.data(), false, false);
#else
  return process->object_heap()->allocate_internal_byte_array(0);
#endif
}

} // namespace toit
