// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_ZEPHYR
#include "flash_registry.h"
#include <zephyr/drivers/flash.h>
#include <zephyr/storage/flash_map.h>
#include <zephyr/sys/barrier.h>

#define TOIT_PLATFORM DT_COMPAT_GET_ANY_STATUS_OKAY(toit_platform)
#define STORAGE_NODE DT_PHANDLE(TOIT_PLATFORM, storage_partition)

namespace toit {
// NVMC invalidates caches when entering write/erase mode. Program each word
// at most once between erases, within Nordic's two-write limit even for byte
// updates. Rewriting an existing word uses a recoverable page transaction.
BUILD_ASSERT(IS_ENABLED(CONFIG_SOC_NRF5340_CPUAPP));
BUILD_ASSERT(DT_REG_SIZE(STORAGE_NODE) >= 3 * FLASH_PAGE_SIZE);
BUILD_ASSERT(DT_REG_SIZE(STORAGE_NODE) % FLASH_PAGE_SIZE == 0);
BUILD_ASSERT(DT_REG_ADDR(STORAGE_NODE) % FLASH_PAGE_SIZE == 0);
static const flash_area* area;
static uint8* base;
static K_MUTEX_DEFINE(storage_mutex);
static uint32 page_buffer[FLASH_PAGE_SIZE / sizeof(uint32)];
static const word registry_size = DT_REG_SIZE(STORAGE_NODE) - 2 * FLASH_PAGE_SIZE;
static const word journal_header = registry_size;
static const word journal_data = registry_size + FLASH_PAGE_SIZE;
static const uint32 JOURNAL_MAGIC = 0x544f4954;
struct Journal {
  uint32 offset;
  uint32 data_crc;
  uint32 header_crc;
  uint32 committed;
};
uint8* FlashRegistry::allocations_memory_ = null;

static bool valid_range(word offset, word size) {
  return offset >= 0 && size >= 0 && offset <= registry_size && size <= registry_size - offset;
}
static bool erased(const uint8* bytes, word length) {
  for (word i = 0; i < length; i++) if (bytes[i] != 0xff) return false;
  return true;
}
static bool erase_page(word offset) {
  // Complete a full erase even if an interrupted erase left readable 0xff.
  if (flash_area_erase(area, offset, FLASH_PAGE_SIZE) != 0) return false;
  return erased(base + offset, FLASH_PAGE_SIZE);
}
// Skip unchanged words, including erased words. Never consume a programming
// cycle by writing 0xffffffff to an erased word.
static bool write_words(word offset, const uint32* words, word count) {
  for (word i = 0; i < count; i++) {
    uint32 old;
    memcpy(&old, base + offset + i * sizeof(uint32), sizeof(old));
    if (old == words[i]) continue;
    if (old != 0xffffffff) return false;
    if (flash_area_write(area, offset + i * sizeof(uint32), &words[i], sizeof(uint32)) != 0) return false;
  }
  return memcmp(base + offset, words, count * sizeof(uint32)) == 0;
}
static uint32 checksum(const void* bytes, word size) {
  return Utils::crc32(JOURNAL_MAGIC, static_cast<const uint8*>(bytes), size);
}
static bool recover_journal(bool report) {
  Journal record;
  memcpy(&record, base + journal_header, sizeof(record));
  // An incomplete descriptor can be left by staging or by retiring an already
  // completed transaction. The destination is not erased until the complete
  // descriptor and final commit word have been verified.
  if (record.committed != JOURNAL_MAGIC ||
      record.header_crc != checksum(&record, offsetof(Journal, header_crc))) return true;
  if (!valid_range(record.offset, FLASH_PAGE_SIZE) ||
      record.offset % FLASH_PAGE_SIZE != 0 ||
      record.data_crc != checksum(base + journal_data, FLASH_PAGE_SIZE)) return false;
  memcpy(page_buffer, base + journal_data, FLASH_PAGE_SIZE);
  if (memcmp(base + record.offset, page_buffer, FLASH_PAGE_SIZE) != 0) {
    if (report) printf("[toit] recovering flash page at registry offset 0x%lx\n",
                       static_cast<unsigned long>(record.offset));
    if (!erase_page(record.offset) ||
        !write_words(record.offset, page_buffer, ARRAY_SIZE(page_buffer))) return false;
  }
  return erase_page(journal_header);
}
static bool rewrite_page(word offset) {
  // Persist the new page and descriptor before changing the destination.
  // Retire the descriptor only after verifying the complete destination.
  if (!erase_page(journal_header) || !erase_page(journal_data) ||
      !write_words(journal_data, page_buffer, ARRAY_SIZE(page_buffer))) return false;
  Journal record = {};
  record.offset = offset;
  record.data_crc = checksum(page_buffer, FLASH_PAGE_SIZE);
  record.header_crc = checksum(&record, offsetof(Journal, header_crc));
  record.committed = JOURNAL_MAGIC;
  uint32 record_words[sizeof(Journal) / sizeof(uint32)];
  memcpy(record_words, &record, sizeof(record));
  if (!write_words(journal_header, record_words, 3) ||
      !write_words(journal_header + offsetof(Journal, committed), &record.committed, 1)) return false;
  if (!erase_page(offset) || !write_words(offset, page_buffer, ARRAY_SIZE(page_buffer))) return false;
  return erase_page(journal_header);
}

void FlashRegistry::set_up() {
  ASSERT(allocations_memory_ == null);
  if (flash_area_open(DT_FIXED_PARTITION_ID(STORAGE_NODE), &area) != 0 ||
      !device_is_ready(area->fa_dev) || flash_area_align(area) != sizeof(uint32)) {
    FATAL("invalid flash registry partition");
  }
  flash_pages_info info;
  if (flash_get_page_info_by_offs(area->fa_dev, area->fa_off, &info) != 0 ||
      info.size != FLASH_PAGE_SIZE) FATAL("unsupported flash erase geometry");
  base = reinterpret_cast<uint8*>(DT_REG_ADDR(DT_CHOSEN(zephyr_flash)) + area->fa_off);
  allocations_memory_ = base;
  if (!recover_journal(true)) FATAL("flash registry recovery failed");
}
void FlashRegistry::tear_down() {
  flash_area_close(area);
  area = null;
  base = null;
  allocations_memory_ = null;
}
void FlashRegistry::flush() { barrier_dmem_fence_full(); }
int FlashRegistry::allocations_size() { return registry_size; }

bool FlashRegistry::write_chunk(const void* chunk, word offset, word size) {
  if (!area || !valid_range(offset, size)) return false;
  k_mutex_lock(&storage_mutex, K_FOREVER);
  Defer unlock { [&] { k_mutex_unlock(&storage_mutex); } };
  if (!recover_journal(false)) return false;
  const uint8* source = static_cast<const uint8*>(chunk);
  while (size > 0) {
    word page = Utils::round_down(offset, FLASH_PAGE_SIZE);
    word within = offset - page;
    word count = Utils::min(size, FLASH_PAGE_SIZE - within);
    memcpy(page_buffer, base + page, FLASH_PAGE_SIZE);
    uint8* bytes = reinterpret_cast<uint8*>(page_buffer);
    for (word i = 0; i < count; i++) bytes[within + i] &= source[i];
    bool needs_erase = false;
    const uint32* old = reinterpret_cast<const uint32*>(base + page);
    for (word i = 0; i < static_cast<word>(ARRAY_SIZE(page_buffer)); i++) {
      if (old[i] != page_buffer[i] && old[i] != 0xffffffff) needs_erase = true;
    }
    if (needs_erase) {
      if (!rewrite_page(page)) return false;
    } else if (!write_words(page, page_buffer, ARRAY_SIZE(page_buffer))) {
      return false;
    }
    source += count;
    offset += count;
    size -= count;
  }
  return true;
}
int FlashRegistry::erase_chunk(word offset, word size) {
  if (!area || !valid_range(offset, size) || offset % FLASH_PAGE_SIZE != 0) return 0;
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  if (!valid_range(offset, size)) return 0;
  k_mutex_lock(&storage_mutex, K_FOREVER);
  Defer unlock { [&] { k_mutex_unlock(&storage_mutex); } };
  if (!recover_journal(false)) return 0;
  for (word cursor = offset; cursor < offset + size; cursor += FLASH_PAGE_SIZE) {
    if (!erase_page(cursor)) return 0;
  }
  return size;
}
bool FlashRegistry::erase_flash_registry() {
  return erase_chunk(0, registry_size) == registry_size;
}
}  // namespace toit
#endif
