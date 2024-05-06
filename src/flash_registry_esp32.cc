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

#ifdef TOIT_ESP32

#include "flash_registry.h"

#include <math.h>

#include "esp_partition.h"
#include "spi_flash_mmap.h"

namespace toit {

static const esp_partition_t* allocations_partition = null;
static spi_flash_mmap_handle_t allocations_handle;
uint8* FlashRegistry::allocations_memory_ = null;

static bool is_erased_page(word offset) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  return FlashRegistry::is_erased(offset, FLASH_PAGE_SIZE);
}

static esp_err_t ensure_erased(word offset, word size) {
  FlashRegistry::flush();
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
      esp_err_t result = esp_partition_erase_range(allocations_partition, cursor, dirty_to - cursor);
      if (result != ESP_OK) {
        return result;
      }
      cursor = dirty_to;  // Will continue at [dirty_to] + FLASH_PAGE_SIZE.
    }
  }
  return ESP_OK;
}

void FlashRegistry::set_up() {
  ASSERT(allocations_partition == null);
  allocations_partition = esp_partition_find_first(
      static_cast<esp_partition_type_t>(0x40),
      static_cast<esp_partition_subtype_t>(0x00),
      null);
  ASSERT(allocations_partition != null);
  ASSERT(allocations_memory() == null);
  const void* memory = null;
  esp_partition_mmap(allocations_partition, 0, allocations_size(), ESP_PARTITION_MMAP_DATA, &memory, &allocations_handle);
  allocations_memory_ = reinterpret_cast<uint8*>(const_cast<void*>(memory));
  ASSERT(allocations_memory() != null);
}

void FlashRegistry::tear_down() {
  allocations_memory_ = null;
  spi_flash_munmap(allocations_handle);
  allocations_partition = null;
}

void FlashRegistry::flush() {
}

int FlashRegistry::allocations_size() {
  return static_cast<int>(allocations_partition->size);
}

int FlashRegistry::erase_chunk(word offset, word size) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  esp_err_t result = ensure_erased(offset, size);
  if (result == ESP_OK) {
    // Flush to make sure we don't find stale cached information.
    FlashRegistry::flush();
    return size;
  } else {
    return 0;
  }
}

bool FlashRegistry::write_chunk(const void* chunk, word offset, word size) {
  esp_err_t result = esp_partition_write(allocations_partition, offset, chunk, size);
  return result == ESP_OK;
}

bool FlashRegistry::erase_flash_registry() {
  ASSERT(allocations_partition != null);
  esp_err_t result = esp_partition_erase_range(allocations_partition, 0, allocations_partition->size);
  return result == ESP_OK;
}

} // namespace toit

#endif // TOIT_ESP32
