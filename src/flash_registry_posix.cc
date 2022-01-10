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

#ifdef TOIT_POSIX

#include "flash_registry.h"
#include "objects_inline.h"
#include "flash_allocation.h"
#include "scheduler.h"
#include "vm.h"

#include <fcntl.h>
#include <math.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>

namespace toit {

static const int ALLOCATION_SIZE = 2 * MB;
static const int ENCRYPTION_WRITE_SIZE = 16;

static void* allocations = null;
const char* FlashRegistry::allocations_memory_ = null;

static bool is_file_backed = false;
static bool is_dirty = false;

void FlashRegistry::set_up() {
  ASSERT(allocations == null);
  ASSERT(allocations_memory() == null);

  int fd = -1;
  int flags = MAP_ANONYMOUS | MAP_SHARED;
  int padding = 0;

  const char* path = getenv("TOIT_FLASH_REGISTRY_FILE");
  if (path != null) {
    fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (fd < 0) {
      FATAL("Cannot open '%s' for file-backed memory for FlashRegistry", path);
    }
    if (ftruncate(fd, ALLOCATION_SIZE) != 0) {
      perror("FlashRegistry::set_up/ftruncate");
    }

    flags = MAP_SHARED;
    is_file_backed = true;
  }

  long page_size = sysconf(_SC_PAGE_SIZE);
  if (page_size != Utils::round_up(page_size, FLASH_PAGE_SIZE)) {
    padding = FLASH_PAGE_SIZE;
  }

  if (padding > 0 && is_file_backed) {
    FATAL("Cannot use non-aligned file-backed memory for FlashRegistry");
  }

  // We use mmap here instead of regular allocation because this is emulating
  // the flash on the device so we don't want it to show up in heap accounting.
  allocations = mmap(null, allocations_size() + padding, PROT_READ | PROT_WRITE, flags, fd, 0);
  allocations_memory_ = Utils::round_up(unvoid_cast<char*>(allocations), FLASH_PAGE_SIZE);

  if (allocations == MAP_FAILED) {
    FATAL("Failed to allocate memory for FlashRegistry");
  }

  if (padding == 0 && allocations != allocations_memory_) {
    FATAL("Cannot allocate aligned memory for FlashRegistry");
  }

  if (fd >= 0) {
    close(fd);
  }
}

bool FlashRegistry::is_allocations_set_up() {
  return allocations != null;
}

void FlashRegistry::flush() {
  if (!is_dirty || !is_file_backed) return;
  // TODO(kasper): Track the dirty region instead.
  msync(void_cast(const_cast<char*>(allocations_memory_)), allocations_size(), MS_SYNC);
  is_dirty = false;
}

int FlashRegistry::allocations_size() {
  return ALLOCATION_SIZE;
}

int FlashRegistry::erase_chunk(int offset, int size) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  memset(memory(offset, size), 0xff, size);
  is_dirty = true;
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
  is_dirty = true;
  return true;
}

/*
  The boolean expression ~(d ^ s) | (s & ~d) has the truth table:

  +---+---+---------------------+
  | s | d | ~(d ^ s) | (s & ~d) |
  +---+---+---------------------+
  | 1 | 1 | 1                   |
  | 1 | 0 | 1                   |
  | 0 | 1 | 0                   |
  | 0 | 0 | 1                   |
  +---+---+---------------------+

  So an invalid write to flash (i.e. flipping 0 to 1) results in 0.
*/
bool is_valid_write(void* memory, const void* chunk, int offset, int size) {
  char* dest = reinterpret_cast<char*>(memory);
  char* src = reinterpret_cast<char*>(const_cast<void*>(chunk));
  for (int i = 0; i < size; i++) {
    char in_memory = dest[i];
    char write = src[i];
    if ((~(in_memory ^ write) | (write & ~in_memory)) == 0xff) return false;
  }
  return true;
}

int FlashRegistry::read_raw_chunk(int offset, void* destination, int size) {
  memcpy(destination, memory(offset, size) , size);
  return size;
}

bool FlashRegistry::write_raw_chunk(const void* chunk, int offset, int size) {
  void* dest = memory(offset, size);
  ASSERT(is_valid_write(dest, chunk, offset, size));
  memcpy(dest, chunk, size);
  is_dirty = true;
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
