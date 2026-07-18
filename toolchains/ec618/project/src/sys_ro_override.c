// Copyright (C) 2026 Toit contributors.
//
// Override sysROSpaceCheck from libstartup.a to allow Toit to write
// to Toit's writable flash regions inside the AP image area.
//
// The linker resolves object-file symbols before archive symbols, so
// this definition takes precedence over the one in libstartup.a.

#include <stdint.h>
#include <assert.h>

#include "mem_map.h"

// AP_IMAGE_END below assumes the Toit layout's __USER_CODE__ size. Fail
// the build if the SDK map and this protection boundary drift apart.
_Static_assert(AP_FLASH_LOAD_SIZE == 0x2E0000,
               "sys_ro_override.c hard-codes AP_IMAGE_END assuming __USER_CODE__");

// Writable window for flash operations. Set these before performing
// flash writes to regions inside the AP image area (flash registry, OTA).
uint32_t toit_ap_image_modify_start = 0;
uint32_t toit_ap_image_modify_end   = 0;

#define BOOTLOADER_END  0x22000
#define AP_IMAGE_START  0x24000
#define AP_IMAGE_END    0x304000  // 0x24000 + 0x2E0000.

static uint8_t sysROAddrCheck(uint32_t addr) {
    if (addr < BOOTLOADER_END) {
        return 1;  // Bootloader — always read-only.
    }
    // The SDK owns LittleFS and may format or update it during early boot,
    // before Toit's explicit flash-write windows exist. Its geometry is
    // frozen with the base, but its contents are intentionally writable.
    if (addr >= FLASH_FS_REGION_START && addr < FLASH_FS_REGION_END) {
        return 0;
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
