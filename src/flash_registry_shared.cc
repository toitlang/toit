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

int FlashRegistry::find_next(word offset, ReservationList::Iterator* it) {
  ASSERT(is_allocations_set_up());
  if (offset >= allocations_size()) return -1;

  // If we are at a reserved slot, we return the address immediately after the reservation.
  if ((*it) != ReservationList::Iterator(null) && (*it)->left() == offset) {
    return (*it)->right();
  }

  // If we are at an allocation, we return the address immediately after the allocation.
  const FlashAllocation* probe = reinterpret_cast<const FlashAllocation*>(allocations_memory() + offset);
  if (probe->is_valid()) {
    return offset + probe->size();
  }

  // We are at a hole. Return the first address that is not part of the hole.
  for (word i = offset + FLASH_PAGE_SIZE; i < allocations_size(); i += FLASH_PAGE_SIZE) {
    if ((*it) != ReservationList::Iterator(null) && (*it)->left() == i) return i;
    const FlashAllocation* probe = reinterpret_cast<const FlashAllocation*>(allocations_memory() + i);
    if (probe->is_valid()) return i;
  }
  return allocations_size();
}

const FlashAllocation* FlashRegistry::allocation(word offset) {
  const FlashAllocation* result = null;
  if ((offset & 1) == 0) {
    FlashAllocation* probe = reinterpret_cast<FlashAllocation*>(region(offset, 0));
    if (probe->is_valid()) result = probe;
  } else {
#ifdef TOIT_FREERTOS
    const EmbeddedDataExtension* extension = EmbeddedData::extension();
    const Program* probe = const_cast<Program*>(extension->program(offset - 1));
    if (probe->is_valid_embedded()) result = probe;
#endif
  }
  return result;
}

static bool is_erased_unaligned(const uint8* memory, word from, word to) {
  for (word i = from; i < to; i++) {
    if (memory[i] != 0xff) return false;
  }
  return true;
}

static bool is_erased_aligned(const uint8* memory, word from, word to) {
  ASSERT(Utils::is_aligned(memory + from, sizeof(uword)));
  ASSERT(Utils::is_aligned(memory + to, sizeof(uword)));
  const uword* cursor = reinterpret_cast<const uword*>(memory + from);
  const uword* limit = reinterpret_cast<const uword*>(memory + to);
  while (cursor < limit) {
    if (*cursor != static_cast<uword>(-1)) return false;
    ++cursor;
  }
  return true;
}

bool FlashRegistry::is_erased(word offset, word size) {
  const uint8* memory = region(offset, size);
  word cursor = 0;

  word from_aligned = Utils::round_up(offset, sizeof(uword));
  word unaligned_prefix = from_aligned - offset;
  if (unaligned_prefix > 0) {
    if (!is_erased_unaligned(memory, 0, unaligned_prefix)) return false;
    cursor = unaligned_prefix;
  }

  word to = offset + size;
  word to_aligned = Utils::round_down(to, sizeof(uword));
  word aligned_middle = to_aligned - from_aligned;
  if (aligned_middle > 0) {
    word cursor_next = cursor + aligned_middle;
    if (!is_erased_aligned(memory, cursor, cursor_next)) return false;
    cursor = cursor_next;
  }

  return is_erased_unaligned(memory, cursor, size);
}

}
