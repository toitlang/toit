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

#ifdef CONFIG_IDF_TARGET_ESP32
  #include <esp32/rom/cache.h>
#endif

namespace toit {

static const esp_partition_t* allocations_partition = null;
static spi_flash_mmap_handle_t allocations_handle;
const char* FlashRegistry::allocations_memory_ = null;

static bool is_dirty = false;

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
      esp_err_t result = esp_partition_erase_range(allocations_partition, cursor, dirty_end - cursor);
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
  ASSERT(allocations_partition == null);
  allocations_partition = esp_partition_find_first(
      static_cast<esp_partition_type_t>(0x40),
      static_cast<esp_partition_subtype_t>(0x00),
      null);
  ASSERT(allocations_partition != null);
  ASSERT(allocations_memory() == null);
  const void* memory = null;
  esp_partition_mmap(allocations_partition, 0, allocations_size(), SPI_FLASH_MMAP_DATA, &memory, &allocations_handle);
  allocations_memory_ = static_cast<const char*>(memory);
  ASSERT(allocations_memory() != null);
}

void FlashRegistry::tear_down() {
  allocations_memory_ = null;
  spi_flash_munmap(allocations_handle);
  allocations_partition = null;
}

bool FlashRegistry::is_allocations_set_up() {
  return allocations_memory_ != null;
}

void FlashRegistry::flush() {
  if (!is_dirty) return;
#if !defined(CONFIG_IDF_TARGET_ESP32C3) && !defined(CONFIG_IDF_TARGET_ESP32S3) && !defined(CONFIG_IDF_TARGET_ESP32S2)
  Cache_Flush(0);
#ifndef CONFIG_FREERTOS_UNICORE
  Cache_Flush(1);
#endif
#endif
  is_dirty = false;
}

int FlashRegistry::allocations_size() {
  return static_cast<int>(allocations_partition->size);
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
  esp_err_t result = esp_partition_write(allocations_partition, offset, chunk, size);
  if (result == ESP_OK) {
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
  ASSERT(allocations_partition != null);
  esp_err_t result = esp_partition_erase_range(allocations_partition, 0, allocations_partition->size);
  return result == ESP_OK;
}

} // namespace toit

#endif // TOIT_FREERTOS
