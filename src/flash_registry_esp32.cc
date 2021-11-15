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

#ifdef TOIT_FREERTOS

#include "flash_registry.h"

#include <math.h>

#include "esp_partition.h"
#include "esp_spi_flash.h"
#include <esp32/rom/cache.h>

namespace toit {

static const esp_partition_t* allocations = null;
const char* FlashRegistry::allocations_memory_ = null;

static bool is_dirty = false;

static uint32_t to_raw_address(int offset) {
  return allocations->address + offset;
}

static bool is_clean_page(const char* memory, unsigned offset) {
  uint32_t* cursor = reinterpret_cast<uint32_t*>(const_cast<char*>(memory + offset));
  uint32_t* end = cursor + FLASH_PAGE_SIZE / sizeof(uint32_t);
  do {
    if (*cursor != 0xffffffff) return false;
    ++cursor;
  } while (cursor < end);

  return true;
}

static esp_err_t ensure_erased(const char* memory, unsigned offset, int size) {
  FlashRegistry::flush();
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  ASSERT(Utils::is_aligned(size, FLASH_PAGE_SIZE));
  unsigned end = offset + size;
  for (unsigned cursor = offset; cursor < end; cursor += FLASH_PAGE_SIZE) {
    if (!is_clean_page(memory, cursor)) {
      // Determine size of dirty range.
      unsigned dirty_end = cursor + FLASH_PAGE_SIZE;
      while (dirty_end < end && !is_clean_page(memory, dirty_end)) {
        dirty_end += FLASH_PAGE_SIZE;
      }
      // Erase dirty range: [cursor, dirty_end).
      esp_err_t result = esp_partition_erase_range(allocations, cursor, dirty_end - cursor);
      if (result == ESP_OK) {
        is_dirty = true;
      } else {
        return result;
      }
      cursor = dirty_end;  // Will continue at [dirty_end] + FLASH_PAGE_SIZE.
    }
  }
  return ESP_OK;
}

void FlashRegistry::set_up() {
  ASSERT(allocations == null);
  allocations = esp_partition_find_first(
      static_cast<esp_partition_type_t>(0x40),
      static_cast<esp_partition_subtype_t>(0x00),
      null);
  ASSERT(allocations != null);
  ASSERT(allocations_memory() == null);
  const void* memory = null;
  spi_flash_mmap_handle_t handle;
  esp_partition_mmap(allocations, 0, allocations_size(), SPI_FLASH_MMAP_DATA, &memory, &handle);
  allocations_memory_ = static_cast<const char*>(memory);
  printf("[flash reg] address %p, size 0x%08x\n", allocations_memory(), allocations_size());
  ASSERT(allocations_memory() != null);
}

bool FlashRegistry::is_allocations_set_up() {
  return allocations != null;
}

void FlashRegistry::flush() {
  if (!is_dirty) return;
  Cache_Flush(0);
#ifndef CONFIG_FREERTOS_UNICORE
  Cache_Flush(1);
#endif
  is_dirty = false;
}

int FlashRegistry::allocations_size() {
  return static_cast<int>(allocations->size);
}

int FlashRegistry::erase_chunk(int offset, int size) {
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  esp_err_t result = ensure_erased(FlashRegistry::allocations_memory(), offset, size);
  if (result == ESP_OK) {
    // TODO(kasper): Not strictly necessary if we always proceed to overwrite
    // the erased section with the image. For now, we sometimes use this to
    // erase a program header (see _Program.remove in programs_registry.toit)
    // and to make sure the following flash scan doesn't find pseudo-erased
    // programs, we flush here.
    FlashRegistry::flush();
    return size;
  } else {
    return 0;
  }
}

bool FlashRegistry::write_chunk(const void* chunk, int offset, int size) {
  esp_err_t result = esp_partition_write(allocations, offset, chunk, size);
  if (result == ESP_OK) {
    is_dirty = true;
    return true;
  } else {
    return false;
  }
}

int FlashRegistry::read_raw_chunk(int offset, void* destination, int size) {
  uint32_t raw_address = to_raw_address(offset);
  ASSERT(0 <= offset && raw_address + size < allocations->address + allocations_size());
  // TODO(lau): Use esp_flash_read - could potentially reduce code size.
  esp_err_t result = spi_flash_read(raw_address, destination, size);
  return  result == ESP_OK;
}

bool FlashRegistry::write_raw_chunk(const void* chunk, int offset, int size) {
  uint32_t raw_address = to_raw_address(offset);
  ASSERT(0 <= offset && raw_address + size < allocations->address + allocations_size());
  // TODO(lau): Use esp_flash_write - could potentially reduce code size.
  esp_err_t result = spi_flash_write(raw_address, chunk, size);
  if (result == ESP_OK) {
    FlashRegistry::flush();
    is_dirty = true;
    return true;
  } else {
    return false;
  }
}

int FlashRegistry::offset(const void* cursor) {
  ASSERT(allocations_memory() != null);
  int offset = reinterpret_cast<int>(cursor) - reinterpret_cast<int>(allocations_memory());
  ASSERT(0 <= offset && offset < allocations_size());
  return offset;
}

bool FlashRegistry::erase_flash_registry() {
  ASSERT(allocations != null);
  esp_err_t result = esp_partition_erase_range(allocations, 0, allocations->size);
  return result == ESP_OK;
}

} // namespace toit

#endif // TOIT_FREERTOS
