// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_RP2040
#include "hardware/flash.h"
#include "hardware/sync.h"
#undef FLASH_PAGE_SIZE
#include "flash_registry.h"
#ifdef TOIT_RP2040_TEST_STORAGE_INTERRUPTION
#include "../toolchains/rp2040/storage-interruption-test.h"
#endif

namespace toit {
// The updater reserves this space between its metadata and executable slot.
static const uint32 registry_offset = 0x12000;
static const uint32 registry_size = 0xe000;
uint8* FlashRegistry::allocations_memory_ = null;

void FlashRegistry::set_up() {
  allocations_memory_ = reinterpret_cast<uint8*>(XIP_BASE + registry_offset);
}
void FlashRegistry::tear_down() { allocations_memory_ = null; }
void FlashRegistry::flush() {}
int FlashRegistry::allocations_size() { return registry_size; }

int FlashRegistry::erase_chunk(word offset, word size) {
  if (offset < 0 || size < 0 || (offset & (FLASH_PAGE_SIZE - 1)) ||
      static_cast<uword>(offset) > registry_size ||
      static_cast<uword>(size) > registry_size - offset) return 0;
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  for (word at = offset; at < offset + size; at += FLASH_PAGE_SIZE) {
    if (is_erased(at, FLASH_PAGE_SIZE)) continue;
#ifdef TOIT_RP2040_TEST_STORAGE_INTERRUPTION
    rp2040_storage_test_before_erase(registry_offset + at);
#endif
    uint32 irq = save_and_disable_interrupts();
    flash_range_erase(registry_offset + at, FLASH_PAGE_SIZE);
    restore_interrupts(irq);
    if (!is_erased(at, FLASH_PAGE_SIZE)) return 0;
  }
  return size;
}

bool FlashRegistry::write_chunk(const void* chunk, word offset, word size) {
  if (offset < 0 || size < 0 || static_cast<uword>(offset) > registry_size ||
      static_cast<uword>(size) > registry_size - offset) return false;
  const uint8* bytes = static_cast<const uint8*>(chunk);
#ifdef TOIT_RP2040_TEST_STORAGE_INTERRUPTION
  rp2040_storage_test_arm(chunk, size);
  bool header = size == 48 && (offset & (FLASH_PAGE_SIZE - 1)) == 0 &&
      bytes[0] == 0xce && bytes[1] == 0xfa && bytes[2] == 0xad && bytes[3] == 0xde;
#endif
  uint8 page[256];
  while (size) {
    word base = offset & ~255;
    word start = offset - base;
    word count = Utils::min(word(256) - start, size);
    memcpy(page, allocations_memory_ + base, sizeof(page));
    for (word i = 0; i < count; i++) {
      if ((page[start + i] & bytes[i]) != bytes[i]) return false;
      page[start + i] = bytes[i];
    }
#ifdef TOIT_RP2040_TEST_STORAGE_INTERRUPTION
    rp2040_storage_test_before_program(registry_offset + base, page, header);
#endif
    uint32 irq = save_and_disable_interrupts();
    flash_range_program(registry_offset + base, page, sizeof(page));
    restore_interrupts(irq);
#ifdef TOIT_RP2040_TEST_STORAGE_INTERRUPTION
    rp2040_storage_test_after_program(header);
#endif
    if (memcmp(allocations_memory_ + offset, bytes, count)) return false;
    offset += count;
    bytes += count;
    size -= count;
  }
  return true;
}

bool FlashRegistry::erase_flash_registry() {
  return erase_chunk(0, registry_size) == registry_size;
}
}  // namespace toit
#endif
