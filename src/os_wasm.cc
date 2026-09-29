// Copyright (C) 2026 Toit contributors.
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

#ifdef TOIT_WASM

#include <emscripten/heap.h>
#include <unistd.h>

#include "os.h"
#include "memory.h"
#include "program_memory.h"
#include "utils.h"

namespace toit {

char* OS::get_executable_path() {
  return strdup("/toit.wasm");
}

int OS::num_cores() {
  return 1;
}

void OS::free_block(ProgramBlock* block) {
  free_pages(void_cast(block), TOIT_PAGE_SIZE);
}

// WebAssembly has no virtual memory. The linear memory only grows, and
// memory that has been grown is readable and writable. The only user of
// grab_virtual_memory is the GC metadata, which covers the whole linear
// memory (see get_heap_memory_range).
void* OS::grab_virtual_memory(void* address, uword size) {
  // Newly grown linear memory is zero-filled and not yet backed by physical
  // pages, so taking it directly from sbrk avoids touching (and thus paying
  // for) the parts of the metadata that are never used. The GC metadata is
  // allocated at startup, before the memory above the break has been used.
  size = Utils::round_up(size, TOIT_PAGE_SIZE);
  uword current = reinterpret_cast<uword>(sbrk(0));
  uword padding = Utils::round_up(current, TOIT_PAGE_SIZE) - current;
  void* result = sbrk(size + padding);
  if (result == reinterpret_cast<void*>(-1)) return null;
  return Utils::void_add(result, padding);
}

void OS::ungrab_virtual_memory(void* address, uword size) {
  // Memory taken with sbrk can't be given back. The metadata lives for the
  // whole lifetime of the module.
}

bool OS::use_virtual_memory(void* address, uword size) {
  return true;
}

void OS::unuse_virtual_memory(void* address, uword size) {}

OS::HeapMemoryRange OS::get_heap_memory_range() {
  // All pages are allocated with aligned_alloc from the linear memory, which
  // can grow up to the maximum heap size. The GC metadata thus has to cover
  // everything up to that size.
  HeapMemoryRange range;
  range.address = null;
  range.size = Utils::round_up(static_cast<uword>(emscripten_get_heap_max()), TOIT_PAGE_SIZE);
  return range;
}

void* OS::allocate_pages(uword size) {
  size = Utils::round_up(size, TOIT_PAGE_SIZE);
  return aligned_alloc(TOIT_PAGE_SIZE, size);
}

void OS::free_pages(void* address, uword size) {
  free(address);
}

void OS::set_writable(ProgramBlock* block, bool value) {
  // No memory protection in WebAssembly.
}

const char* OS::get_platform() {
  return "Wasm";
}

int OS::read_entire_file(char* name, uint8** buffer) {
  FILE* file = fopen(name, "rb");
  if (!file) return -1;
  fseek(file, 0, SEEK_END);
  word length = ftell(file);
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

void OS::set_heap_tag(word tag) {}
word OS::get_heap_tag() { return 0; }

}  // namespace toit

#endif  // TOIT_WASM
