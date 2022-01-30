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

#ifdef TOIT_DARWIN

#include "os.h"
#include "flags.h"
#include "memory.h"
#include "program_memory.h"
#include <sys/time.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <mach/mach_init.h>
#include <mach/mach_error.h>
#include <mach/task.h>
#include <unistd.h>

namespace toit {

int OS::num_cores() {
  int count;
  size_t count_len = sizeof(count);
  sysctlbyname("hw.logicalcpu", &count, &count_len, null, 0);
  return count;
}


void OS::free_block(Block* block) {
  int result = munmap(void_cast(block), TOIT_PAGE_SIZE);
  USE(result);
  ASSERT(result == 0);
}

void OS::free_block(ProgramBlock* block) {
  int result = munmap(void_cast(block), TOIT_PAGE_SIZE);
  USE(result);
  ASSERT(result == 0);
}

Block* OS::allocate_block() {
#if BUILD_64
  uword size = TOIT_PAGE_SIZE * 2;
  void* result = mmap(null, size,
       PROT_READ | PROT_WRITE,
       MAP_PRIVATE | MAP_ANON, -1, 0);
  if (result == MAP_FAILED) return null;
  uword addr = reinterpret_cast<uword>(result);
  uword aligned = Utils::round_up(addr, TOIT_PAGE_SIZE);
  if (aligned != addr) {
    // Unmap the part at the beginning that we can't use because of alignment.
    int unmap_result = munmap(reinterpret_cast<void*>(addr), aligned - addr);
    USE(unmap_result);
    ASSERT(unmap_result == 0);
  }
  if (aligned + TOIT_PAGE_SIZE != addr + size) {
    // Unmap the part at the end that we can't use because of alignment.
    int unmap_result = munmap(reinterpret_cast<void*>(aligned + TOIT_PAGE_SIZE), addr + size - aligned - TOIT_PAGE_SIZE);
    USE(unmap_result);
    ASSERT(unmap_result == 0);
  }
  return new (reinterpret_cast<void*>(aligned)) Block();
#else
  // Using 4k pages on 32 bit we know that the result of mmap will always be
  // page aligned.
  void* result = mmap(null, TOIT_PAGE_SIZE,
       PROT_READ | PROT_WRITE,
       MAP_PRIVATE | MAP_ANON, -1, 0);
  return (result == MAP_FAILED) ? null : new (result) Block();
#endif
}

ProgramBlock* OS::allocate_program_block() {
#if BUILD_64
  uword size = TOIT_PAGE_SIZE * 2;
  void* result = mmap(null, size,
       PROT_READ | PROT_WRITE,
       MAP_PRIVATE | MAP_ANON, -1, 0);
  if (result == MAP_FAILED) return null;
  uword addr = reinterpret_cast<uword>(result);
  uword aligned = Utils::round_up(addr, TOIT_PAGE_SIZE);
  if (aligned != addr) {
    // Unmap the part at the beginning that we can't use because of alignment.
    int unmap_result = munmap(reinterpret_cast<void*>(addr), aligned - addr);
    USE(unmap_result);
    ASSERT(unmap_result == 0);
  }
  if (aligned + TOIT_PAGE_SIZE != addr + size) {
    // Unmap the part at the end that we can't use because of alignment.
    int unmap_result = munmap(reinterpret_cast<void*>(aligned + TOIT_PAGE_SIZE), addr + size - aligned - TOIT_PAGE_SIZE);
    USE(unmap_result);
    ASSERT(unmap_result == 0);
  }
  return new (reinterpret_cast<void*>(aligned)) ProgramBlock();
#else
  // Using 4k pages on 32 bit we know that the result of mmap will always be
  // page aligned.
  void* result = mmap(null, TOIT_PAGE_SIZE,
       PROT_READ | PROT_WRITE,
       MAP_PRIVATE | MAP_ANON, -1, 0);
  return (result == MAP_FAILED) ? null : new (result) ProgramBlock();
#endif
}

void OS::set_writable(ProgramBlock* block, bool value) {
  mprotect(void_cast(block), TOIT_PAGE_SIZE, PROT_READ | (value ? PROT_WRITE : 0));
}

void OS::tear_down() {
  free(_global_mutex);
  free(_scheduler_mutex);
}

const char* OS::get_platform() {
  return "macOS";
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

void OS::set_heap_tag(word tag) { }
word OS::get_heap_tag() { return 0; }
void OS::heap_summary_report(int max_pages, const char* marker) { }

}

#endif // TOIT_DARWIN
