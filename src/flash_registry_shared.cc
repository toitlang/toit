// Copyright (C) 2019 Toitware ApS.
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
#include "os.h"
#include "flash_registry.h"

namespace toit {

int FlashRegistry::find_next(int offset, ReservationList::Iterator* it) {
  ASSERT(is_allocations_set_up());
  if (offset >= allocations_size()) return -1;

  // If we are at a reserved slot, we return the address immediately after the reservation.
  if ((*it) != ReservationList::Iterator(null) && (*it)->left() == offset) {
    return (*it)->right();
  }
  // If we are at an allocation, we return the address immediately after the allocation.
  const FlashAllocation* probe = reinterpret_cast<const FlashAllocation*>(allocations_memory() + offset);
  if (probe->is_valid(offset, OS::image_uuid())) {
    return offset + probe->size();
  }

  // We are at a hole. Return the first address that is not part of the hole.
  for (int i = offset + FLASH_PAGE_SIZE; i < allocations_size(); i += FLASH_PAGE_SIZE) {
    if ((*it) != ReservationList::Iterator(null) && (*it)->left() == i) return i;
    const FlashAllocation* probe = reinterpret_cast<const FlashAllocation*>(allocations_memory() + i);
    if (probe->is_valid(i, OS::image_uuid())) return i;
  }
  return allocations_size();
}

const FlashAllocation* FlashRegistry::at(int offset) {
  ASSERT(is_allocations_set_up());
  ASSERT(0 <= offset && offset < allocations_size());
  const FlashAllocation* probe = reinterpret_cast<const FlashAllocation*>(memory(offset, 0));
  return (probe->is_valid(offset, OS::image_uuid())) ? probe : null;
}

bool FlashRegistry::pad_and_write(const void* chunk, int offset, int size) {
  if (size % FLASH_SEGMENT_SIZE == 0) {
    return FlashRegistry::write_chunk(chunk, offset, size);
  }
  int aligned_size = Utils::round_down(size, FLASH_SEGMENT_SIZE);
  bool success = FlashRegistry::write_chunk(chunk, offset, aligned_size);
  if (!success) {
    return false;
  }
  uint8_t last_segment[FLASH_SEGMENT_SIZE];  // TODO(Lau): Make statically allocated.
  memset(last_segment, 0xFF, FLASH_SEGMENT_SIZE);
  int remainder_length = size % FLASH_SEGMENT_SIZE;
  memcpy(last_segment, static_cast<char*>(const_cast<void*>(chunk)) + aligned_size, remainder_length);
  return FlashRegistry::write_chunk(last_segment, offset + aligned_size, FLASH_SEGMENT_SIZE);
}

void* FlashRegistry::memory(int offset, int size) {
  if ((offset & 1) == 0) {
    ASSERT(allocations_memory() != null);
    ASSERT(0 <= offset && offset + size <= allocations_size());
    return const_cast<char*>(allocations_memory()) + offset;
  }

#ifdef TOIT_FREERTOS
  const uword* table = OS::image_bundled_programs_table();
  uword diff = static_cast<uword>(offset - 1);
  return reinterpret_cast<void*>(reinterpret_cast<uword>(table) + diff);
#else
  return null;
#endif
}

}
