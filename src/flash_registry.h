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

#pragma once

#include "flash_allocation.h"

namespace toit {

class FlashRegistry {
 public:
  static void set_up();

  // Flush the caches before reading.
  static void flush();

  // Find next empty slot.
  static int find_next(int offset, ReservationList::Iterator* reservations);
  static const FlashAllocation* at(int offset);

  // Flash writing support.
  static int erase_chunk(int offset, int size);
  // This write may use encryption. Therefore, writes must be 16 byte aligned and target erased memory.
  static bool write_chunk(const void* chunk, int offset, int size);

  // This write pads the chunk to make it 16 byte aligned.
  static bool pad_and_write(const void* chunk, int offset, int size);

  // Get a pointer to the memory of an allocation.
  // If encryption is enabled, then reads from this pointer will be implicitly decrypted.
  static void* memory(int offset, int size);

  // Flash writing support for direct access to flash.
  // These operations access the flash directly circumventing any encryption and decryption.
  static int read_raw_chunk(int offset, void* destination, int size);
  static bool write_raw_chunk(const void* chunk, int offset, int size);

  // Get the offset from the cursor.
  static int offset(const void* cursor);

  // Erase the flash registry.
  static bool erase_flash_registry();

  // Get the size of the allocations area in bytes.
  static int allocations_size();

 private:
  static const char* allocations_memory() { return allocations_memory_; }
  static bool is_allocations_set_up();

  static const char* allocations_memory_;
};

} // namespace toit
