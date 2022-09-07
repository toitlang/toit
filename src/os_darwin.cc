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
#include <errno.h>

namespace toit {

int OS::num_cores() {
  int count;
  size_t count_len = sizeof(count);
  sysctlbyname("hw.logicalcpu", &count, &count_len, null, 0);
  return count;
}


void OS::free_block(ProgramBlock* block) {
  free_pages(void_cast(block), TOIT_PAGE_SIZE);
}

void* OS::grab_virtual_memory(void* address, uword size) {
  size = Utils::round_up(size, getpagesize());
  void* result = mmap(address, size,
      PROT_NONE,
      MAP_PRIVATE | MAP_ANON, -1, 0);
  if (result == MAP_FAILED) return null;
  return result;
}

void OS::ungrab_virtual_memory(void* address, uword size) {
  size = Utils::round_up(size, getpagesize());
  if (size > 0) {
    int result = munmap(address, size);
    if (result != 0) {
      perror("munmap");
      exit(1);
    }
  }
}

bool OS::use_virtual_memory(void* addr, uword sz) {
  ASSERT(addr != null);
  if (sz == 0) return true;
  uword address = reinterpret_cast<uword>(addr);
  uword end = address + sz;
  uword rounded = Utils::round_down(address, getpagesize());
  uword size = Utils::round_up(end - rounded, getpagesize());
  int result = mprotect(reinterpret_cast<void*>(rounded), size, PROT_READ | PROT_WRITE);
  if (result == 0) return true;
  if (errno == ENOMEM) return false;
  perror("mprotect");
  exit(1);
}

void OS::unuse_virtual_memory(void* addr, uword sz) {
  uword address = reinterpret_cast<uword>(addr);
  uword end = address + sz;
  uword rounded = Utils::round_up(address, getpagesize());
  uword size = Utils::round_down(end - rounded, getpagesize());
  if (size != 0) {
    int result = mprotect(reinterpret_cast<void*>(rounded), size, PROT_NONE);
    if (result == 0) return;
    perror("mprotect");
    exit(1);
  }
}

void OS::set_writable(ProgramBlock* block, bool value) {
  mprotect(void_cast(block), TOIT_PAGE_SIZE, PROT_READ | (value ? PROT_WRITE : 0));
}

void OS::tear_down() {
  free(_global_mutex);
  free(_scheduler_mutex);
  free(_resource_mutex);
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
void OS::heap_page_report() { }

}

#endif // TOIT_DARWIN
