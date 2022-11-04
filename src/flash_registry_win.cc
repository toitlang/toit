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

static const int ALLOCATION_SIZE = 2 * MB;
static const int ENCRYPTION_WRITE_SIZE = 16;

const char* FlashRegistry::allocations_memory_ = null;
static void* allocations_malloced = null;

void FlashRegistry::set_up() {
  ASSERT(allocations_malloced == null);
  ASSERT(allocations_memory() == null);

  allocations_malloced = malloc(ALLOCATION_SIZE + FLASH_PAGE_SIZE);
  allocations_memory_ = Utils::round_up(unvoid_cast<char*>(allocations_malloced), FLASH_PAGE_SIZE);
}

void FlashRegistry::tear_down() {
  allocations_memory_ = null;
  free(allocations_malloced);
  allocations_malloced = null;
}

bool FlashRegistry::is_allocations_set_up() {
  return allocations_memory_ != null;
}

void FlashRegistry::flush() {
  // No flushing necessary.
}

int FlashRegistry::allocations_size() {
  return ALLOCATION_SIZE;
}

int FlashRegistry::erase_chunk(int offset, int size) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  memset(memory(offset, size), 0xff, size);
  return size;
}

bool is_erased(void* memory, int offset, int size) {
  char* dest = reinterpret_cast<char*>(memory);
  for (int i = 0; i < size; i++) {
    uint8 value = dest[i];
    if (value != 0xff) {
      return false;
    }
  }
  return true;
}

bool FlashRegistry::write_chunk(const void* chunk, int offset, int size) {
  void* dest = memory(offset, size);
  ASSERT(Utils::is_aligned(offset, ENCRYPTION_WRITE_SIZE));
  ASSERT(Utils::is_aligned(size, ENCRYPTION_WRITE_SIZE));
  ASSERT(is_erased(dest, 0, size));
  memcpy(dest, chunk, size);
  return true;
}

int FlashRegistry::offset(const void* cursor) {
  ASSERT(allocations_memory() != null);
  word offset = Utils::address_distance(allocations_memory(), cursor);
  ASSERT(0 <= offset && offset < allocations_size());
  return offset;
}

bool FlashRegistry::erase_flash_registry() {
  ASSERT(allocations_memory() != null);
  FlashRegistry::erase_chunk(0, allocations_size());
  return true;
}

} // namespace toit

#endif // defined(TOIT_LINUX) || defined(TOIT_BSD)
