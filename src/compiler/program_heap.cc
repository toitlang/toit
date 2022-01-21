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

String* ProgramHeap::allocate_string(const char* str) {
  return allocate_string(str, strlen(str));
}

String* ProgramHeap::allocate_string(const char* str, int length) {
  bool internal = length <= String::max_internal_size();
  word allocation_size = internal ?
      String::internal_allocation_size(length) :
      String::external_allocation_size();
  void* address = _top;
  _top += allocation_size;
  if (_top - _memory > _size) {
    return null;
  }
  String* result = reinterpret_cast<String*>(HeapObject::cast(address));
  Smi* string_id = _program->string_class_id();
  result->_set_header(string_id, _program->class_tag_for(string_id));
  if (internal) {
    result->_set_length(length);
  } else {
    result->_set_external_length(length);
    uint8* external_data = _top;
    _top += Utils::round_up(length + 1, 8);
    if (_top - _memory > _size) {
      return null;
    }
    result->_set_external_address(external_data);
  }
  String::Bytes bytes(result);
  memcpy(bytes.address(), str, length);
  bytes._set_end();
  result->_assign_hash_code();
  return result;
}

Instance* ProgramHeap::allocate_instance(Smi* class_id) {
  int size = _program->instance_size_for(class_id);
  TypeTag class_tag = _program->class_tag_for(class_id);
  return allocate_instance(class_tag, class_id, Smi::from(size));
}

void ProgramHeap::do_pointers(PointerCallback* callback) {
}

}  // namespace toit.

