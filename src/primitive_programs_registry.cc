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
  ARGS(int, offset, int, group_id, Object, arguments);

  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  if (!allocation) FAIL(OUT_OF_BOUNDS);
  if (allocation->type() != FLASH_ALLOCATION_TYPE_PROGRAM) FAIL(INVALID_ARGUMENT);
  Program* program = const_cast<Program*>(static_cast<const Program*>(allocation));

  unsigned message_size = 0;
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
  if (!initial_memory_manager.allocate()) FAIL(ALLOCATION_FAILED);

  ProcessGroup* process_group = ProcessGroup::create(group_id, program);
  if (!process_group) FAIL(MALLOC_FAILED);
  AllocationManager free_process_group(process, process_group);

  initial_memory_manager.global_variables = program->global_variables.copy();
  if (!initial_memory_manager.global_variables) FAIL(MALLOC_FAILED);

  // Takes over the encoder and the initial_memory_manager.
  int pid = VM::current()->scheduler()->run_program(program, &encoder, process_group, &initial_memory_manager);
  if (pid == Scheduler::INVALID_PROCESS_ID) FAIL(MALLOC_FAILED);
  free_process_group.keep_result();
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
  ARGS(int, offset);
  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  if (!allocation) FAIL(OUT_OF_BOUNDS);
  if (allocation->type() != FLASH_ALLOCATION_TYPE_PROGRAM) FAIL(INVALID_ARGUMENT);
  const Program* program = static_cast<const Program*>(allocation);
  return BOOL(VM::current()->scheduler()->kill(program));
}

PRIMITIVE(bundled_images) {
#ifdef TOIT_ESP32
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
#elif defined(TOIT_FREERTOS)
  FAIL(UNIMPLEMENTED);
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
#ifdef TOIT_ESP32
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  List<uint8> config = extension->config();
  Object* result = config.is_empty()
      ? process->object_heap()->allocate_internal_byte_array(0)
      : process->object_heap()->allocate_external_byte_array(config.length(), config.data(), false, false);
#elif defined(TOIT_FREERTOS)
  FAIL(UNIMPLEMENTED);
#else
  Object* result = process->object_heap()->allocate_internal_byte_array(0);
#endif
  if (!result) FAIL(ALLOCATION_FAILED);
  return result;
}

} // namespace toit
