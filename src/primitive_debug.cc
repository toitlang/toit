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

static int encode_histogram(ProgramOrientedEncoder* encoder, PerClass* data, int length, int entries, const char* marker) {
  encoder->write_header(entries * 3 + 1, 'O');  // O for objects.  See mirror.toit.
  encoder->write_string(marker);
  int non_trivial_entries = 0;
  for (int i = 0; i < length; i++) {
    if (data[i].size > 0) {
      non_trivial_entries++;
      encoder->write_int(i);
      encoder->write_int(data[i].count);
      encoder->write_int(data[i].size);
    }
  }
  return non_trivial_entries;
}

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

  // First encoding to find the size.
  MallocedBuffer length_counting_buffer(1);
  if (!length_counting_buffer.has_content()) MALLOC_FAILED;
  ProgramOrientedEncoder length_counting_encoder(program, &length_counting_buffer);
  int non_trivial_entries = encode_histogram(&length_counting_encoder, data, length, 0, marker);

  // Second encoding to actually encode into a buffer.
  MallocedBuffer encoding_buffer(length_counting_buffer.size());
  if (!encoding_buffer.has_content()) MALLOC_FAILED;
  ProgramOrientedEncoder encoder(program, &encoding_buffer);
  encode_histogram(&encoder, data, length, non_trivial_entries, marker);

  ByteArray* result = process->object_heap()->allocate_external_byte_array(
      encoding_buffer.size(),
      encoding_buffer.content(),
      /* dispose = */ true,
      /* clear_content = */ false);
  if (result == null) ALLOCATION_FAILED;
  process->object_heap()->register_external_allocation(encoding_buffer.size());
  encoding_buffer.take_content();  // Don't free the content!
  return result;
}

} // namespace toit
