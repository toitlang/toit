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

// mem_map.h expresses image load addresses in the AP's XIP address space,
// while sysROSpaceCheck receives raw flash offsets. Derive every boundary
// from that SDK map instead of copying its current evaluated addresses.
#define RAW_FLASH_OFFSET(xip_address) ((xip_address) - AP_FLASH_XIP_ADDR)
#define BOOTLOADER_END \
  (RAW_FLASH_OFFSET(BOOTLOADER_FLASH_LOAD_ADDR) + BOOTLOADER_FLASH_LOAD_SIZE)
#define AP_IMAGE_START RAW_FLASH_OFFSET(AP_FLASH_LOAD_ADDR)
#define AP_IMAGE_END (AP_IMAGE_START + AP_FLASH_LOAD_SIZE)

_Static_assert(BOOTLOADER_END <= AP_IMAGE_START,
               "bootloader and AP image overlap");
_Static_assert(AP_IMAGE_END == FLASH_FOTA_REGION_START,
               "AP image does not end at the SDK FOTA boundary");

// Writable window for flash operations. Set these before performing
// flash writes to regions inside the AP image area (flash registry, OTA).
uint32_t toit_ap_image_modify_start = 0;
uint32_t toit_ap_image_modify_end   = 0;

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
