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

#if defined(TOIT_LINUX)

#include "os.h"
#include "flags.h"
#include "memory.h"
#include "program_memory.h"
#include <sys/time.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/sysinfo.h>
#include <unistd.h>

namespace toit {

int OS::num_cores() {
  return get_nprocs();
}

void OS::free_block(Block* block) {
  free_pages(void_cast(block), TOIT_PAGE_SIZE);
}

static bool initialized_ = false;
static uword allocation_arena_;
static uword allocation_size_;
static void* arena_mapping_;
static uword arena_mapping_size_;
static uint8* allocation_map_;
static Mutex* allocation_mutex_ = null;

void OS::free_pages(void* p, uword size) {
  uword address = reinterpret_cast<uword>(p);
  ASSERT(address == Utils::round_up(address, TOIT_PAGE_SIZE));
  int page = static_cast<int>((address - allocation_arena_) >> TOIT_PAGE_SIZE_LOG2);
  for (int i = 0; i < size >> TOIT_PAGE_SIZE_LOG2; i++) {
    ASSERT(allocation_map_[page + i] != 0);
    allocation_map_[page + i] = 0;
  }
  int mprotect_result = mprotect(p, size, PROT_NONE);
  if (mprotect_result < 0) {
    perror("mprotect");
    exit(1);
  }
}

void OS::free_block(ProgramBlock* block) {
  free_pages(void_cast(block), TOIT_PAGE_SIZE);
}

void* OS::allocate_pages(uword size, int arenas) {
  ASSERT(initialized_);
  ASSERt(size == Utils::round_up(size, TOIT_PAGE_SIZE));
  int pages = static_cast<int>(size >> TOIT_PAGE_SIZE_LOG2);
  int allocation_map_size = static_cast<int>(arena_mapping_size_ >> TOIT_PAGE_SIZE_LOG2);
  for (int i = 0; i <= allocation_map_size - pages; ) {
    bool ok = true;
    for (int j = i + pages - 1; j >= i; j--) {
      if (allocation_map_[j] != 0) {
        ok = false;
        i = j + 1;
        break;
      }
    }
    if (!ok) continue;
    auto result = reinterpret_cast<void*>(location_arena_ + i * TOIT_PAGE_SIZE;
    int mprotect_result = mprotect(result, size, PROT_WRITE | PROT_READ);
    if (mprotect_result < 0) {
      perror("mprotect");
      exit(1);
    }
    for (int j = i; j < i + pages; j++) {
      ASSERT(allocation_map_[page + i] == 0);
      allocation_map_[j] = 1;
    }
    return result;
  }
  return null;
}

Block* OS::allocate_block() {
  void* aligned = allocate_pages(TOIT_PAGE_SIZE, ANY_ARENA);
  if (!aligned) return null;
  return new (aligned) Block();
}

ProgramBlock* OS::allocate_program_block() {
  void* aligned = allocate_pages(TOIT_PAGE_SIZE, ANY_ARENA);
  if (!aligned) return null;
  return new (aligned) ProgramBlock();
}

void OS::set_writable(ProgramBlock* block, bool value) {
  mprotect(void_cast(block), TOIT_PAGE_SIZE, PROT_READ | (value ? PROT_WRITE : 0));
}

OS::platform_set_up() {
  ASSERT(!initialized_);
#if BUILD_64
  arena_mapping_size_ = 2024 * MB;
#else
  arena_mapping_size_ = 512 * MB;
#endif
  arena_mapping_ = mmap(null, arena_mapping_size_, PROT_NONE, MAP_PRIVATE, MAP_ANON, -1, 0);
  while (!arena_mapping_) {
    arena_mapping_size_ >>= 1;
    if (arena_mapping_size_ < 64 * MB) {
      FATAL("Failed to reserve address space");
    }
    arena_mapping_ = mmap(null, arena_mapping_size_, PROT_NONE, MAP_PRIVATE, MAP_ANON, -1, 0);
  }
  allocation_arena_ = Utils::round_up(reinterpret_cast<uword>(arena_mapping_), TOIT_PAGE_SIZE);
  uword end = Utils::round_down(arena_mapping_ + arena_mapping_size_, TOIT_PAGE_SIZE);
  allocation_size_ = end - allocation_arena_;
  allocation_map_ = calloc(allocation_size_ / TOIT_PAGE_SIZE, 1);
  initialized_ = true;
}

void OS::tear_down() {
  dispose(_global_mutex);
  dispose(_scheduler_mutex);
}

const char* OS::get_platform() {
  return "Linux";
}

int OS::read_entire_file(char* name, uint8** buffer) {
  FILE *file;
  int length;
  file = fopen(name, "rb");
  if (!file) return -1;
  fseek(file, 0, SEEK_END);
  length = ftell(file);
  fseek(file, 0, SEEK_SET);
  *buffer = unvoid_cast<uint8*>(malloc(length + 1));
  if (!*buffer) {
    fclose(file);
    return -2;
  }
  size_t result = fread(*buffer, length, 1, file);
  if (result != 1) {
    fclose(file);
    return -3;
  }
  fclose(file);
  return length;
}

#ifdef TOIT_CMPCTMALLOC

void OS::set_heap_tag(word tag) {
  int MALLOC_OPTION_THREAD_TAG = 1;
  if (heap_caps_set_option != null) {
    heap_caps_set_option(MALLOC_OPTION_THREAD_TAG, void_cast(tag));
  }
}

word OS::get_heap_tag() {
  int MALLOC_OPTION_THREAD_TAG = 1;
  if (heap_caps_set_option != null) {
    return reinterpret_cast<word>(heap_caps_get_option(MALLOC_OPTION_THREAD_TAG));
  }
  return 0;
}


#else // def TOIT_CMPCTMALLOC

void OS::set_heap_tag(word tag) { }
word OS::get_heap_tag() { return 0; }

#endif // def TOIT_CMPCTMALLOC

void OS::heap_summary_report(int max_pages, const char* marker) { }

}

#endif // TOIT_LINUX
