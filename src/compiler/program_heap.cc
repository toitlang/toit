// Copyright (C) 2022 Toitware ApS.
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

#include "program_heap.h"
#include "../program.h"
#include "../utils.h"

namespace toit {

ProgramHeap::ProgramHeap(Program* program) : _program(program) {
  _size = 10 * 1024 * 1024;
  _memory = unvoid_cast<uint8*>(malloc(_size));
  _top = _memory;
  _program->set_heap(this);
}

uint8* ProgramHeap::allocate_bytes(int count) {
  result = _top;
  if (_top + count > _memory + _size) return null;
  _top += count;
  return result;
}

HeapObject* ProgramHeap::_allocate_raw(int allocation_size) {
  uword heap_size = size();
  uword rounded = Utils::round_up(heap_size, sizeof(word));
  if (heap_size!= rounded) {
    allocate_bytes(rounded - heap_size);
  }
  return HeapObject::cast(allocate_bytes(allocation_size));
}

String* ProgramHeap::allocate_string(const char* str) {
  return allocate_string(str, strlen(str));
}

String* ProgramHeap::allocate_string(const char* str, int length) {
  bool internal = length <= String::max_internal_size();
  word allocation_size = internal ?
      String::internal_allocation_size(length) :
      String::external_allocation_size();
  auto heap_object = _allocate_raw(allocation_size);
  Smi* string_id = _program->string_class_id();
  heap_object->_set_header(string_id, _program->class_tag_for(string_id));
  auto result = String::cast(heap_object);
  if (internal) {
    result->_set_length(length);
  } else {
    result->_set_external_length(length);
    uint8* external_data = allocate_bytes(length + 1);
    result->_set_external_address(external_data);
  }
  String::Bytes bytes(result);
  memcpy(bytes.address(), str, length);
  bytes._set_end();
  result->_assign_hash_code();
  return result;
}

ByteArray* allocate_byte_array(const uint8* data, int length) {
  bool internal = length <= ByteArray::max_internal_size();
  word allocation_size = internal ?
      ByteArray::internal_allocation_size(length) :
      ByteArray::external_allocation_size();
  auto heap_object = _allocate_raw(allocation_size);
  Smi* byte_array_id = _program->byte_array_class_id();
  heap_object->_set_header(_program, byte_array_id);
  auto result = ByteArray::cast(heap_object);
  if (internal) {
    result->_initialize(length);
  } else {
    uint8* external_data = allocate_bytes(length + 1);
    result->_initialize_external_memory(length, external_data, false);
  }
  Bytes bytes(result);
  memcpy(bytes.address(), data, length);
  return result;
}

Array* allocate_array(int length, Object* filler) {
  word allocation_size = Array::allocation_size(length);
  auto heap_object = _allocate_raw(allocation_size);
  Smi* array_id = _program->array_class_id();
  heap_object->_set_header(_program, array_id);
  auto result = Array::cast(heap_object);
  result->_initialize(length, filler);
  return result;
}

Instance* ProgramHeap::allocate_instance(Smi* class_id) {
  int allocation_size = _program->instance_size_for(class_id);
  TypeTag class_tag = _program->class_tag_for(class_id);
  auto heap_object = _allocate_raw(allocation_size);
  heap_object->_set_header(class_id, class_tag);
  return Instance::cast(heap_object);
}

Double* ProgramHeap::allocate_double(double value) {
  auto heap_object = _allocate_raw(Double::allocation_size();
  heap_object->_set_header(_program, _program->double_class_id());
  auto result = Double::cast(result);
  result->_initialize(value);
  return result;
}

LargeInteger* ProgramHeap::allocate_large_integer(int64 value) {
  auto heap_object = _allocate_raw(LargeInteger::allocation_size();
  heap_object->_set_header(_program, _program->large_integer_class_id());
  auto result = LargeInteger::cast(result);
  result->_initialize(value);
  return result;
}

void ProgramHeap::do_pointers(PointerCallback* callback) {
  for (uint8* addr = _memory; addr < _top; ) {
    auto heap_object = HeapObject::cast(void_cast(addr));
    int size = heap_object->size(_program);
    addr += size;
    auto tag = heap_object->class_tag();
    if (tag == BYTE_ARRAY_TAG) {
      auto byte_array = ByteArray::cast(heap_object);
      if (byte_array.has_external_address()) {
      }
    } else if (tag == STRING_TAG) {
      auto string = String::cast(heap_object);
    } else {
    }
  }
}

}  // namespace toit.

