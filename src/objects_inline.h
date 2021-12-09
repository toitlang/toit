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
#include "tags.h"

namespace toit {

inline Process* HeapObject::owner() {
#ifdef TOIT_FREERTOS
  // On embedded targets the program heap is in flash and not aligned, so it is
  // not OK to try to load the owner from the page header.
  uword address = reinterpret_cast<uword>(this);
  USE(address);
  size_t size;
  uint8* data = OS::program_data(&size);
  USE(data);
  ASSERT(!(address - reinterpret_cast<uword>(data) < size));
#endif
  return Block::from(this)->process();
}


inline int Array::max_length() {
  return (Block::max_payload_size() - HEADER_SIZE) / WORD_SIZE;
}

inline int Stack::max_length() {
  return (Block::max_payload_size() - HEADER_SIZE) / WORD_SIZE;
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

} // namespace toit
