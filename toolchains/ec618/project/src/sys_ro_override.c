// Copyright (C) 2026 Toit contributors.
//
// Override sysROSpaceCheck from libstartup.a to allow Toit to write
// to the flash registry region, which falls inside the AP image area
// when __USER_CODE__ is defined (AP_FLASH_LOAD_SIZE = 0x2E0000).
//
// The linker resolves object-file symbols before archive symbols, so
// this definition takes precedence over the one in libstartup.a.

#include <stdint.h>
#include <assert.h>

#include "mem_map.h"

// AP_IMAGE_END below assumes __USER_CODE__ is defined, which gives
// AP_FLASH_LOAD_SIZE = 0x2E0000. If a future build drops that flag,
// AP_FLASH_LOAD_SIZE shrinks to 0x280000 and the 384 KB reserved area
// between 0x2A4000 and 0x304000 would silently fall outside the AP-image
// guard and become writable here. Fail the build before that happens.
_Static_assert(AP_FLASH_LOAD_SIZE == 0x2E0000,
               "sys_ro_override.c hard-codes AP_IMAGE_END assuming __USER_CODE__");

// Writable window for flash operations. Set these before performing
// flash writes to regions inside the AP image area (flash registry, OTA).
uint32_t toit_ap_image_modify_start = 0;
uint32_t toit_ap_image_modify_end   = 0;

#define BOOTLOADER_END  0x22000
#define AP_IMAGE_START  0x24000
#define AP_IMAGE_END    0x304000  // 0x24000 + 0x2E0000

static uint8_t sysROAddrCheck(uint32_t addr) {
    if (addr < BOOTLOADER_END) {
        return 1;  // Bootloader — always read-only.
    }
    if (addr >= AP_IMAGE_START && addr < AP_IMAGE_END) {
        // Allow if inside the Toit-designated writable window.
        if (toit_ap_image_modify_start <= addr
            && addr < toit_ap_image_modify_end) {
            return 0;
        }
        return 1;  // AP image — read-only by default.
    }
    return 0;  // Everything else is writable.
}

uint8_t sysROSpaceCheck(uint32_t addr, uint32_t size) {
    if (sysROAddrCheck(addr))            return 1;
    if (size > 0 && sysROAddrCheck(addr + size - 1)) return 1;
    return 0;
}
