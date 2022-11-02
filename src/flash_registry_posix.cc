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

static void* allocations_mmap = null;
static size_t allocations_mmap_size = 0;
const char* FlashRegistry::allocations_memory_ = null;

static bool is_file_backed = false;

static long pagesize = 0;
static int dirty_start = INT32_MAX;
static int dirty_end = 0;

static bool is_dirty() {
  return dirty_start < dirty_end;
}

static void mark_dirty(int offset, int size) {
  dirty_start = Utils::min(dirty_start, offset);
  dirty_end = Utils::max(dirty_end, offset + size);
}

void FlashRegistry::set_up() {
  ASSERT(allocations_mmap == null);
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

  pagesize = sysconf(_SC_PAGESIZE);
  if (pagesize != Utils::round_up(pagesize, FLASH_PAGE_SIZE)) {
    padding = FLASH_PAGE_SIZE;
  }

  if (padding > 0 && is_file_backed) {
    FATAL("Cannot use non-aligned file-backed memory for FlashRegistry");
  }

  // We use mmap here instead of regular allocation because this is emulating
  // the flash on the device so we don't want it to show up in heap accounting.
  allocations_mmap_size = allocations_size() + padding;
  allocations_mmap = mmap(null, allocations_mmap_size, PROT_READ | PROT_WRITE, flags, fd, 0);
  allocations_memory_ = Utils::round_up(unvoid_cast<char*>(allocations_mmap), FLASH_PAGE_SIZE);

  if (allocations_mmap == MAP_FAILED) {
    FATAL("Failed to allocate memory for FlashRegistry");
  }

  if (padding == 0 && allocations_mmap != allocations_memory_) {
    FATAL("Cannot allocate aligned memory for FlashRegistry");
  }

  if (fd >= 0) {
    close(fd);
  }

  ASSERT(!is_dirty());
}

void FlashRegistry::tear_down() {
  allocations_memory_ = null;
  if (munmap(allocations_mmap, allocations_mmap_size) != 0) {
    perror("FlashRegistry::tear_down/munmap");
  }
  allocations_mmap = null;
}

bool FlashRegistry::is_allocations_set_up() {
  return allocations_memory_ != null;
}

void FlashRegistry::flush() {
  if (!is_file_backed || !is_dirty()) return;
  int offset = Utils::round_down(dirty_start, pagesize);
  int size = Utils::round_up(dirty_end - offset, pagesize);
  if (msync(void_cast(const_cast<char*>(allocations_memory_) + offset), size, MS_SYNC) != 0) {
    perror("FlashRegistry::flush/msync");
  }
  dirty_start = INT32_MAX;
  dirty_end = 0;
  ASSERT(!is_dirty());
}

int FlashRegistry::allocations_size() {
  return ALLOCATION_SIZE;
}

int FlashRegistry::erase_chunk(int offset, int size) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  memset(memory(offset, size), 0xff, size);
  mark_dirty(offset, size);
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
  mark_dirty(offset, size);
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
