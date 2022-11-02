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

const char* FlashRegistry::allocations_memory_ = null;

void FlashRegistry::set_up() {
}

void FlashRegistry::tear_down() {
}

bool FlashRegistry::is_allocations_set_up() {
  return true;
}

void FlashRegistry::flush() {
  UNIMPLEMENTED();
}

int FlashRegistry::allocations_size() {
  return 0;
}

int FlashRegistry::erase_chunk(int offset, int size) {
  UNIMPLEMENTED();
}

bool FlashRegistry::write_chunk(const void* chunk, int offset, int size) {
  UNIMPLEMENTED();
}

int FlashRegistry::offset(const void* cursor) {
  UNIMPLEMENTED();
}

bool FlashRegistry::erase_flash_registry() {
  UNIMPLEMENTED();
}

} // namespace toit

#endif // defined(TOIT_LINUX) || defined(TOIT_BSD)
