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
#include "embedded_data.h"
#include "flash_registry.h"
#include "program.h"

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
  if (probe->is_valid(offset, EmbeddedData::uuid())) {
    return offset + probe->size();
  }

  // We are at a hole. Return the first address that is not part of the hole.
  for (int i = offset + FLASH_PAGE_SIZE; i < allocations_size(); i += FLASH_PAGE_SIZE) {
    if ((*it) != ReservationList::Iterator(null) && (*it)->left() == i) return i;
    const FlashAllocation* probe = reinterpret_cast<const FlashAllocation*>(allocations_memory() + i);
    if (probe->is_valid(i, EmbeddedData::uuid())) return i;
  }
  return allocations_size();
}

FlashAllocation* FlashRegistry::allocation(int offset) {
  FlashAllocation* result = null;
  if ((offset & 1) == 0) {
    FlashAllocation* probe = reinterpret_cast<FlashAllocation*>(region(offset, 0));
    if (probe->is_valid(offset, EmbeddedData::uuid())) result = probe;
  } else {
#ifdef TOIT_FREERTOS
    const EmbeddedDataExtension* extension = EmbeddedData::extension();
    result = const_cast<Program*>(extension->program(offset - 1));
#endif
  }
  return result;
}

}
