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

#include "top.h"
#include "flash_allocation.h"

namespace toit {

class FlashRegistry {
 public:
  static void set_up();
  static void tear_down();

  // Flush the caches before reading.
  static void flush();

  // Find next empty slot.
  static int find_next(word offset, ReservationList::Iterator* reservations);

  // Get a pointer to the memory of an allocation.
  static const FlashAllocation* allocation(word offset);

  // Get a pointer to the memory of a region.
  static uint8* region(word offset, word size) {
    ASSERT(is_allocations_set_up());
    ASSERT(0 <= offset && offset + size <= allocations_size());
    return reinterpret_cast<uint8*>(allocations_memory()) + offset;
  }

  // Flash writing support.
  static bool write_chunk(const void* chunk, word offset, word size);

  // Get the offset from the cursor.
  static word offset(const void* cursor) {
    ASSERT(is_allocations_set_up());
    word offset = Utils::address_distance(allocations_memory(), cursor);
    ASSERT(0 <= offset && offset < allocations_size());
    return offset;
  }

  // Flash erasing support.
  static bool is_erased(word offset, word size);
  static int erase_chunk(word offset, word size);
  static bool erase_flash_registry();

  // Get the size of the allocations area in bytes.
  static int allocations_size();

  // Verdict cache for untrusted launches of images without the untrusted
  // flag (programs_registry spawn with the untrusted policy): whether the
  // structural verifier accepted the program of [allocation] with the
  // untrusted rules since its memory was last written or erased. Host only
  // (the flash is the VM's own memory, written only through write_chunk and
  // erase_chunk, which clear overlapping entries); always false on devices.
  // Images flagged untrusted carry their verdict in the allocation instead
  // (install-time verification, FlashAllocation::program_verified), on
  // every platform.
  static bool is_verified(const FlashAllocation* allocation);
  static void set_verified(const FlashAllocation* allocation);

 private:
  static void clear_verified(word offset, word size);
  static bool allocation_range(const FlashAllocation* allocation, word* offset, word* size);

  static uint8* allocations_memory() { return allocations_memory_; }
  static bool is_allocations_set_up() { return allocations_memory_ != null; }

  static uint8* allocations_memory_;
};

} // namespace toit
