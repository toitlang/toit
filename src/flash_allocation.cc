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

#include "flash_registry.h"
#include "flash_allocation.h"
#include "os.h"
#include "uuid.h"

namespace toit {

FlashAllocation::FlashAllocation(uint32 allocation_offset) : _header(allocation_offset) {}

FlashAllocation::FlashAllocation() : _header(0) {}

FlashAllocation::Header::Header(uint32 allocation_offset) {
  uint8 uuid[UUID_SIZE] = {0};
  initialize(allocation_offset, uuid, null);
}

void FlashAllocation::Header::set_uuid(const uint8* uuid) {
  memmove(_uuid, uuid, UUID_SIZE);
}

void FlashAllocation::validate() {  }

bool FlashAllocation::is_valid(uint32 allocation_offset, const uint8* uuid) const {
  if (!is_valid_allocation(allocation_offset)) return false;
  return _header.is_valid(uuid);
}

bool FlashAllocation::Header::is_valid(const uint8* uuid) const {
  for (unsigned i = 0; i < UUID_SIZE; i++) {
    if (uuid[i] != _uuid[i]) return false;
  }
  return true;
}

bool FlashAllocation::is_valid_allocation(const uint32 allocation_offset) const {
  return _header.is_valid_allocation(allocation_offset);
}

bool FlashAllocation::Header::is_valid_allocation(const uint32 allocation_offset) const {
  return (_marker == MARKER) && (_me == allocation_offset);
}

bool FlashAllocation::initialize(uint32 offset, uint8 type, const uint8* id, int size, uint8* meta_data) {
  if (static_cast<unsigned>(size) < sizeof(Header)) return false;
  const uint8* uuid = OS::image_uuid();
  void* result = FlashRegistry::memory(offset, size);
  Header header(offset, type, id, uuid, size, meta_data);
  bool success = FlashRegistry::write_chunk(&header, offset, sizeof(header));
  FlashRegistry::flush();
  return success && static_cast<FlashAllocation*>(result)->is_valid(offset, uuid);
}

}  // namespace toit
