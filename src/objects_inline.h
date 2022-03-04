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

#pragma once

#include "objects.h"
#include "memory.h"
#include "heap.h"
#include "program_heap.h"
#include "process.h"
#include "tags.h"
#include "third_party/dartino/gc_metadata.h"

namespace toit {

extern "C" uword toit_image;
extern "C" uword toit_image_size;

int Array::max_length_in_process() {
  return (Heap::max_allocation_size() - HEADER_SIZE) / WORD_SIZE;
}

int Array::max_length_in_program() {
  return (ProgramHeap::max_allocation_size() - HEADER_SIZE) / WORD_SIZE;
}

int Stack::max_length() {
  return (Heap::max_allocation_size() - HEADER_SIZE) / WORD_SIZE;
}

word ByteArray::max_internal_size_in_process() {
  return Heap::max_allocation_size() - HEADER_SIZE;
}

word ByteArray::max_internal_size_in_program() {
  return ProgramHeap::max_allocation_size() - HEADER_SIZE;
}

word String::max_internal_size_in_process() {
  word result = Heap::max_allocation_size() - OVERHEAD;
  return result;
}

word String::max_internal_size_in_program() {
  word result = ProgramHeap::max_allocation_size() - OVERHEAD;
  return result;
}

template<typename T>
T* ByteArray::as_external() {
  int min = T::tag_min;
  int max = T::tag_max;
  ASSERT(min <= external_tag());
  ASSERT(max >= external_tag());
  USE(min);
  USE(max);
  if (has_external_address()) return reinterpret_cast<T*>(_external_address());
  return 0;
}

INLINE void Array::at_put(int index, HeapObject* value) {
  ASSERT(index >= 0 && index < length());
  GcMetadata::insert_into_remembered_set(this);
  _at_put(_offset_from(index), value);
}

INLINE void Array::at_put(int index, Object* value) {
  ASSERT(index >= 0 && index < length());
  if (!value->is_smi()) GcMetadata::insert_into_remembered_set(this);
  _at_put(_offset_from(index), value);
}

inline bool HeapObject::on_program_heap(Process* process) {
  return process->on_program_heap(this);
}

} // namespace toit
