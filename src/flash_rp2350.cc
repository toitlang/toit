// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_RP2350
#include "flash_rp2350.h"
#include "pico/bootrom.h"
#include "boot/picobin.h"
#include <string.h>

namespace toit {
namespace rp2350 {

bool partition(int index, Partition* result) {
  if (index < 0 || index > 2) return false;
  uint32 info[5] = {};
  const uint32 fields = PT_INFO_PARTITION_LOCATION_AND_FLAGS | PT_INFO_PARTITION_ID;
  int count = rom_get_partition_table_info(info, 5,
      (index << 24) | PT_INFO_SINGLE_PARTITION | fields);
  if (count != 5 || (info[0] & fields) != fields ||
      info[3] != static_cast<uint32>(index) || info[4] != 0 ||
      !(info[2] & PICOBIN_PARTITION_FLAGS_HAS_ID_BITS)) return false;
  const uint32 permissions = PICOBIN_PARTITION_PERMISSION_S_R_BITS |
                             PICOBIN_PARTITION_PERMISSION_S_W_BITS;
  if ((info[1] & info[2] & permissions) != permissions) return false;
  uint32 first = (info[1] & PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_BITS) << 12;
  uint32 end = (((info[1] & PICOBIN_PARTITION_LOCATION_LAST_SECTOR_BITS) >>
      PICOBIN_PARTITION_LOCATION_LAST_SECTOR_LSB) + 1) << 12;
  // CS0 only. Preserve the table and the three reserved sectors at the end.
  if (first < 0x2000 || end <= first || end > PICO_FLASH_SIZE_BYTES - 0x3000) return false;
  result->offset = first;
  result->size = end - first;
  result->flags = info[2];
  return true;
}

bool firmware_pair(Partition* a, Partition* b) {
  if (!partition(0, a) || !partition(1, b)) return false;
  const uint32 links = PICOBIN_PARTITION_FLAGS_LINK_TYPE_BITS | PICOBIN_PARTITION_FLAGS_LINK_VALUE_BITS;
  return (a->flags & links) == 0 &&
      (b->flags & links) == PICOBIN_PARTITION_FLAGS_LINK_TYPE_AS_BITS(A_PARTITION) &&
      rom_get_b_partition(0) == 1 && a->size == b->size &&
      a->offset + a->size <= b->offset;
}

const uint8* flash_address(uint32 offset) {
  // Firmware A/B translation covers the active image, not the registry or the
  // inactive image. Use the physical, uncached alias for all storage accesses.
  return reinterpret_cast<const uint8*>(XIP_NOCACHE_NOALLOC_NOTRANSLATE_BASE + offset);
}

static bool flash_op(uint32 op, uint32 offset, uint32 size, uint8* data) {
  cflash_flags_t flags = { (CFLASH_SECLEVEL_VALUE_SECURE << CFLASH_SECLEVEL_LSB) |
                          (op << CFLASH_OP_LSB) };
  // The SDK wrapper excludes interrupts while ROM temporarily disables XIP.
  // Core 1 remains unused; enabling it requires a flash lockout protocol.
  return rom_flash_op(flags, XIP_BASE + offset, size, data) == BOOTROM_OK;
}

bool flash_erase(uint32 offset, uint32 size) {
  if ((offset | size) & 0xfff) return false;
  return flash_op(CFLASH_OP_VALUE_ERASE, offset, size, null);
}

bool flash_write(uint32 offset, const uint8* bytes, uint32 size) {
  // Toit storage writes 16-byte segments; the NOR flash requires 256-byte
  // pages. Preserve untouched bytes and reject attempts to change zero to one.
  // Always stage in SRAM, including input that is itself backed by XIP.
  uint8 page[256];
  while (size != 0) {
    uint32 base = offset & ~255u;
    uint32 start = offset - base;
    uint32 count = size < 256 - start ? size : 256 - start;
    memcpy(page, flash_address(base), sizeof(page));
    for (uint32 i = 0; i < count; i++) {
      if ((page[start + i] & bytes[i]) != bytes[i]) return false;
      page[start + i] = bytes[i];
    }
    if (!flash_op(CFLASH_OP_VALUE_PROGRAM, base, sizeof(page), page)) return false;
    if (memcmp(flash_address(offset), bytes, count) != 0) return false;
    offset += count;
    bytes += count;
    size -= count;
  }
  return true;
}

}  // namespace rp2350
}  // namespace toit
#endif
