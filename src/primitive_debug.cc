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

struct PerClass {
  uint32 count;
  uint32 size;
};

PRIMITIVE(object_histogram) {
  ARGS(cstring, marker);
  Program* program = process->program();
  int length = program->class_bits.length();
  int size = length * sizeof(PerClass);
  MallocedBuffer data_buffer(size);
  if (!data_buffer.has_content()) MALLOC_FAILED;
  PerClass* data = reinterpret_cast<PerClass*>(data_buffer.content());

  // Clear the memory before starting.
  memset(data, 0, size);

  // Iterate through the object heap to collect the histogram.
  process->object_heap()->do_objects([&](HeapObject* object) -> void {
    int class_index = Smi::cast(object->class_id())->value();
    if (class_index < 0) return;  // Free-list entries etc.
    int size = object->size(program);
    if (is_byte_array(object) && ByteArray::cast(object)->has_external_address()) {
      ByteArray* byte_array = ByteArray::cast(object);
      word tag = byte_array->external_tag();
      if (tag == RawByteTag) {
        ByteArray::Bytes bytes(byte_array);
        size += bytes.length();
      }
    } else if (is_string(object) && !String::cast(object)->content_on_heap()) {
      size += String::cast(object)->length() + 1;
    }
    data[class_index].count++;
    data[class_index].size += size;
  });
  int non_trivial_entries = 0;
  int bytes_needed = 0;
  bool size_known = false;
  // Encode twice.  First time with a dry run to calculate the size of the
  // encoded data.
  for (int attempt = 0; attempt < 2; attempt++) {
    MallocedBuffer encoding_buffer(size_known ? bytes_needed : 1);
    if (!encoding_buffer.has_content()) MALLOC_FAILED;
    ProgramOrientedEncoder encoder(program, &encoding_buffer);
    encoder.write_header(non_trivial_entries * 3 + 1, 'O');  // O for objects.  See mirror.toit.
    encoder.write_string(marker);
    for (int i = 0; i < length; i++) {
      if (data[i].size > 0) {
        non_trivial_entries++;
        encoder.write_int(i);
        encoder.write_int(data[i].count);
        encoder.write_int(data[i].size);
      }
    }
    if (size_known) {
      ByteArray* result = process->object_heap()->allocate_external_byte_array(
          encoding_buffer.size(),
          encoding_buffer.content(),
          /* dispose = */ true,
          /* clear_content = */ false);
      if (result == null) ALLOCATION_FAILED;
      process->object_heap()->register_external_allocation(encoding_buffer.size());
      encoding_buffer.take_content();  // Don't free the content!
      return result;
    } else {
      bytes_needed = encoding_buffer.size();
      size_known = true;
    }
  }
  UNREACHABLE();
}

} // namespace toit
