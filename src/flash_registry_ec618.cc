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

#ifdef TOIT_EC618

#include "flash_registry.h"

extern "C" {
  #include "flash_rt.h"
  #include "mem_map.h"
}

namespace toit {

// The flash registry uses a dedicated 384KB region between the AP image and
// the FOTA area. Physical flash address 0x002A4000, accessible via XIP at
// AP_FLASH_XIP_ADDR + 0x002A4000.
static const uint32_t FLASH_REGISTRY_PHYSICAL_OFFSET = 0x002A4000;
static const int FLASH_REGISTRY_SIZE = 384 * 1024;  // 384KB.

uint8* FlashRegistry::allocations_memory_ = null;

static bool is_erased_page(word offset) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  return FlashRegistry::is_erased(offset, FLASH_PAGE_SIZE);
}

static bool ensure_erased(word offset, word size) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  ASSERT(Utils::is_aligned(size, FLASH_PAGE_SIZE));
  int to = offset + size;
  for (word cursor = offset; cursor < to; cursor += FLASH_PAGE_SIZE) {
    if (!is_erased_page(cursor)) {
      // Determine size of dirty range.
      int dirty_to = cursor + FLASH_PAGE_SIZE;
      while (dirty_to < to && !is_erased_page(dirty_to)) {
        dirty_to += FLASH_PAGE_SIZE;
      }
      // Erase dirty range: [cursor, dirty_to).
      uint32_t addr = FLASH_REGISTRY_PHYSICAL_OFFSET + cursor;
      if (BSP_QSPI_Erase_Safe(addr, dirty_to - cursor) != QSPI_OK) {
        return false;
      }
      cursor = dirty_to;  // Will continue at [dirty_to] + FLASH_PAGE_SIZE.
    }
  }
  return true;
}

void FlashRegistry::set_up() {
  ASSERT(allocations_memory() == null);
  // The flash region is accessible via XIP (execute-in-place).
  allocations_memory_ = reinterpret_cast<uint8*>(AP_FLASH_XIP_ADDR + FLASH_REGISTRY_PHYSICAL_OFFSET);
}

void FlashRegistry::tear_down() {
  allocations_memory_ = null;
}

void FlashRegistry::flush() {
  // No data cache on the EC618 Cortex-M3 — nothing to flush.
}

int FlashRegistry::allocations_size() {
  return FLASH_REGISTRY_SIZE;
}

int FlashRegistry::erase_chunk(word offset, word size) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  if (ensure_erased(offset, size)) {
    return size;
  }
  return 0;
}

bool FlashRegistry::write_chunk(const void* chunk, word offset, word size) {
  uint32_t addr = FLASH_REGISTRY_PHYSICAL_OFFSET + offset;
  return BSP_QSPI_Write_Safe(
      const_cast<uint8_t*>(reinterpret_cast<const uint8_t*>(chunk)),
      addr,
      size) == QSPI_OK;
}

bool FlashRegistry::erase_flash_registry() {
  return BSP_QSPI_Erase_Safe(FLASH_REGISTRY_PHYSICAL_OFFSET, FLASH_REGISTRY_SIZE) == QSPI_OK;
}

}  // namespace toit

#endif  // TOIT_EC618
