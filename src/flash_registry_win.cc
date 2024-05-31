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

#include "top.h"

#ifdef TOIT_WINDOWS

#include "flash_registry.h"
#include "flash_allocation.h"

namespace toit {

static const word ALLOCATION_SIZE = 64 * MB;

// An aligned (FLASH_BASED_SIZE) view into the allocations_malloced.
uint8* FlashRegistry::allocations_memory_ = null;
static void* allocations_malloced = null;

void FlashRegistry::set_up() {
  ASSERT(allocations_malloced == null);
  ASSERT(allocations_memory() == null);

  allocations_malloced = malloc(ALLOCATION_SIZE + FLASH_PAGE_SIZE);
  // Align the memory to FLASH_PAGE_SIZE.
  // Note that we allocated FLASH_PAGE_SIZE more than necessary, so we could do this.
  allocations_memory_ = Utils::round_up(unvoid_cast<uint8*>(allocations_malloced), FLASH_PAGE_SIZE);
}

void FlashRegistry::tear_down() {
  allocations_memory_ = null;
  free(allocations_malloced);
  allocations_malloced = null;
}

void FlashRegistry::flush() {
  // No flushing necessary.
}

int FlashRegistry::allocations_size() {
  return ALLOCATION_SIZE;
}

int FlashRegistry::erase_chunk(word offset, word size) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  memset(region(offset, size), 0xff, size);
  return size;
}

bool FlashRegistry::write_chunk(const void* chunk, word offset, word size) {
  uint8* destination = region(offset, size);
  const uint8* source = static_cast<const uint8*>(chunk);
  for (word i = 0; i < size; i++) destination[i] &= source[i];
  return true;
}

bool FlashRegistry::erase_flash_registry() {
  ASSERT(allocations_memory() != null);
  FlashRegistry::erase_chunk(0, allocations_size());
  return true;
}

} // namespace toit

#endif // defined(TOIT_WINDOWS)
