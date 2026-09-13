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
  #include "anchor.h"
  #include "flash_rt.h"
  #include "mem_map.h"
  extern uint8_t toit_booted_slot;
}

namespace toit {

// The flash registry lives in the `registry` partition of the booted
// image's table — historically the SDK's FDB region, which is
// outside the AP image area and not protected by sysROSpaceCheck. Located
// at runtime in set_up(); the zero fallback cannot happen in practice
// (the dispatcher refuses to boot without a valid table) and just makes
// every operation fail closed.
static uint32_t registry_offset = 0;
static int registry_size = 0;

static void locate_registry() {
  partition_entry table[ANCHOR_MAX_ENTRIES];
  int count =
      anchor_table_for_slot(toit_booted_slot, table, ANCHOR_MAX_ENTRIES);
  for (int i = 0; i < count; i++) {
    if (table[i].type == PARTITION_TYPE_DATA && strncmp(table[i].name, "registry", sizeof(table[i].name)) == 0) {
      registry_offset = table[i].offset;
      registry_size = table[i].size;
      return;
    }
  }
}

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
      uint32_t addr = registry_offset + cursor;
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
  locate_registry();
  // The flash region is accessible via XIP (execute-in-place).
  allocations_memory_ = reinterpret_cast<uint8*>(AP_FLASH_XIP_ADDR + registry_offset);
}

void FlashRegistry::tear_down() {
  allocations_memory_ = null;
}

void FlashRegistry::flush() {
  // No data cache on the EC618 Cortex-M3 — nothing to flush.
}

int FlashRegistry::allocations_size() {
  return registry_size;
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
  uint32_t addr = registry_offset + offset;
  // The BSP disables XIP while programming, so even flash-backed input must
  // pass through RAM. Bound the staging space independently of the write:
  // rewriting a multi-page bucket can otherwise need a second large buffer
  // when the storage service already holds its serialized contents in RAM.
  uint8_t buffer[256];
  const uint8_t* source = static_cast<const uint8_t*>(chunk);
  while (size > 0) {
    word count = Utils::min(size, static_cast<word>(sizeof(buffer)));
    memcpy(buffer, source, count);
    if (BSP_QSPI_Write_Safe(buffer, addr, count) != QSPI_OK) return false;
    source += count;
    addr += count;
    size -= count;
  }
  return true;
}

bool FlashRegistry::erase_flash_registry() {
  return BSP_QSPI_Erase_Safe(registry_offset, registry_size) == QSPI_OK;
}

}  // namespace toit

#endif  // TOIT_EC618
