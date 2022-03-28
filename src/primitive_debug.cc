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

#include "top.h"
#include "primitive.h"
#include "process.h"
#include "heap.h"

namespace toit {

MODULE_IMPLEMENTATION(debug, MODULE_DEBUG)

PRIMITIVE(object_histogram) {
  static const int UINT32_PER_ENTRY = 2;
  Program* program = process->program();
  int length = program->class_bits.length();
  int size = length * UINT32_PER_ENTRY * sizeof(uint32);
  uint32* data = unvoid_cast<uint32*>(malloc(size));
  if (data == null) MALLOC_FAILED;

  ByteArray* result = process->object_heap()->allocate_external_byte_array(
      size, reinterpret_cast<uint8*>(data), true, false);
  if (result == null) {
    free(data);
    ALLOCATION_FAILED;
  }

  // Clear the memory before starting.
  process->register_external_allocation(size);
  memset(data, 0, size);

  // Iterate through the object heap to collect the histogram.
  for (ObjectHeap::Iterator it = process->object_heap()->object_iterator(); !it.eos(); it.advance()) {
    HeapObject* object = it.current();
    if (object == result) continue;  // Don't count the resulting byte array.
    int class_index = Smi::cast(object->class_id())->value();
    int size = object->size(program);
    if (object->is_byte_array() && ByteArray::cast(object)->has_external_address()) {
      ByteArray* byte_array = ByteArray::cast(object);
      word tag = byte_array->external_tag();
      if (tag == RawByteTag) {
        ByteArray::Bytes bytes(byte_array);
        size += bytes.length();
      }
    } else if (object->is_string() && !String::cast(object)->content_on_heap()) {
      size += String::cast(object)->length() + 1;
    }
    data[class_index * UINT32_PER_ENTRY + 0] += 1;
    data[class_index * UINT32_PER_ENTRY + 1] += size;
  }
  return result;
}

} // namespace toit
