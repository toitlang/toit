// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Offsets in the Pico W's 2 MiB flash. Updates never write the first 64 KiB.
#define UPDATE_INSTALLED 0x10000u
#define UPDATE_PENDING 0x11000u
#define UPDATE_APP 0x20000u
#define UPDATE_STAGE 0x110000u
#define UPDATE_CAPACITY 0xf0000u
#define UPDATE_SECTOR 4096u
#define UPDATE_PAGE 256u
#define UPDATE_MAGIC 0x31555054u
#define UPDATE_REQUEST 0x52555054u

typedef struct {
  uint32_t magic;
  uint32_t format;
  uint32_t size;
  uint32_t crc;
  uint32_t version;
  uint32_t header_crc;
} UpdateImage;

#ifdef __cplusplus
extern "C" {
#endif

// The hardware implementation uses SRAM buffers and excludes interrupts while
// flash is unavailable. The host test implements NOR flash and power failures.
const uint8_t* update_read(uint32_t offset);
bool update_erase(uint32_t offset);
bool update_program(uint32_t offset, const uint8_t* page);

uint32_t update_crc(const void* bytes, size_t size);
bool update_descriptor_valid(const UpdateImage* image);
bool update_image_valid(uint32_t offset, const UpdateImage* image);
bool update_installed(UpdateImage* image);
bool update_begin(void);
bool update_stage(uint32_t offset, const uint8_t* sector);
bool update_commit(const UpdateImage* image);
// Resumes a committed update after reset. False leaves the updater in recovery.
bool update_install(void);

#ifdef __cplusplus
}  // extern "C"
#endif
