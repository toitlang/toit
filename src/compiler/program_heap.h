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

#pragma once

#include "../top.h"

#include "../objects.h"

namespace toit {

// A program heap contains all the reflective structures to run the program.
class ProgramHeap {
 public:
  ProgramHeap(Program* program);
  String* allocate_string(const char* str);
  String* allocate_string(const char* str, int length);
  ByteArray* allocate_byte_array(const uint8*, int length);
  Array* allocate_array(int length, Object* filler);
  Double* allocate_double(double value);
  LargeInteger* allocate_large_integer(int64 value);
  Instance* allocate_instance(Smi* class_id);
  Instance* allocate_instance(TypeTag class_tag, Smi* class_id, Smi* instance_size);


  HeapObject* allocate_pointers(int count);
  uint8* allocate_bytes(int count);

  const void* address() const { return _memory; }
  word size() const { return _top - _memory; }

  // Iterates the whole program heap.
  void do_pointers(PointerCallback* callback);

 private:
  // Allocates a number of bytes on a word-aligned address.
  HeapObject* _allocate_raw(int size) {
    return HeapObject::cast(allocate_bytes(size));
  }

  Program* _program;
  uint8* _memory;
  uint8* _top;
  word _size;
};

}  // namespace toit.
