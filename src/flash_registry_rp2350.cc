// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_RP2350
#include "flash_registry.h"
#include "flash_rp2350.h"
namespace toit {
static uint8 empty_registry;
static rp2350::Partition registry = {};
uint8* FlashRegistry::allocations_memory_ = null;
void FlashRegistry::set_up() {
  rp2350::Partition a, b;
  registry = {};
  if (rp2350::firmware_pair(&a, &b) && rp2350::partition(2, &registry) &&
      registry.offset >= b.offset + b.size) {
    allocations_memory_ = const_cast<uint8*>(rp2350::flash_address(registry.offset));
  } else {
    registry = {};
    allocations_memory_ = &empty_registry;
  }
}
void FlashRegistry::tear_down() { allocations_memory_ = null; }
void FlashRegistry::flush() {}
int FlashRegistry::allocations_size() { return registry.size; }
int FlashRegistry::erase_chunk(word offset, word size) {
  if (offset < 0 || size < 0 || (offset & (FLASH_PAGE_SIZE - 1)) != 0 ||
      static_cast<uword>(offset) > registry.size ||
      static_cast<uword>(size) > registry.size - offset) return 0;
  size = Utils::round_up(size, FLASH_PAGE_SIZE);
  for (word cursor = offset; cursor < offset + size; cursor += FLASH_PAGE_SIZE) {
    if (!is_erased(cursor, FLASH_PAGE_SIZE) &&
        !rp2350::flash_erase(registry.offset + cursor, FLASH_PAGE_SIZE)) return 0;
  }
  return size;
}
bool FlashRegistry::write_chunk(const void* chunk, word offset, word size) {
  if (offset < 0 || size < 0 || static_cast<uword>(offset) > registry.size ||
      static_cast<uword>(size) > registry.size - offset) return false;
  return rp2350::flash_write(registry.offset + offset, static_cast<const uint8*>(chunk), size);
}
bool FlashRegistry::erase_flash_registry() {
  return registry.size != 0 && erase_chunk(0, registry.size) == static_cast<word>(registry.size);
}
}  // namespace toit
#endif
