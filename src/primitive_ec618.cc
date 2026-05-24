// Copyright (C) 2026 Toit contributors.
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

#ifdef TOIT_EC618

#include "embedded_data.h"
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"
#include "sha.h"

extern "C" {
  #include "flash_rt.h"
  #include "mem_map.h"
}

namespace toit {

// OTA writes new firmware to the FOTA region, then the commit step
// copies it to the active image area on shutdown.
//
// The firmware image has a prefix (VM + system code, from AP_FLASH_LOAD_ADDR
// to the embedded data extension) that is identical between the old and new
// firmware. Only the extension data (snapshots, config) changes. The OTA
// skip the prefix and write only the changed portion.

// Set by ota_end after successful SHA-256 verification, consumed by the
// post-shutdown commit step in toit_ec618.cc.
bool ota_updated = false;
uint32_t ota_commit_prefix_size = 0;     // Active-image offset to write into.
uint32_t ota_commit_extension_size = 0;  // Bytes to copy out of FOTA region.

static bool ota_active = false;
static uint32_t ota_fota_offset = 0;    // Current write position in FOTA region.
static uint32_t ota_prefix_size = 0;    // Bytes to skip (unchanged prefix).
static uint32_t ota_written = 0;        // Total bytes written so far.
static uint32_t ota_total_size = 0;     // Total firmware size (from..to).

MODULE_IMPLEMENTATION(ec618, MODULE_EC618)

PRIMITIVE(ota_begin) {
  ARGS(int, from, int, to);
  if (ota_active) FAIL(ALREADY_IN_USE);
  if (from < 0 || to <= from) FAIL(INVALID_ARGUMENT);

  // Compute the prefix size — the region from AP image start to the
  // embedded data extension, which doesn't change during OTA.
  // AP_FLASH_LOAD_ADDR is already XIP-mapped (the linker uses it as the
  // .text origin), so it must not be combined with AP_FLASH_XIP_ADDR.
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  if (extension == null) FAIL(ERROR);
  uint32_t extension_addr = reinterpret_cast<uint32_t>(extension);
  ota_prefix_size = extension_addr - AP_FLASH_LOAD_ADDR;

  ota_total_size = to - from;
  ota_written = 0;
  ota_fota_offset = FLASH_FOTA_REGION_START;
  ota_active = true;

  return process->null_object();
}

PRIMITIVE(ota_write) {
  ARGS(Blob, bytes);
  if (!ota_active) FAIL(ALREADY_CLOSED);

  const uint8_t* data = bytes.address();
  uint32_t length = bytes.length();
  uint32_t pos = 0;

  while (pos < length) {
    uint32_t global_pos = ota_written + pos;

    // Skip bytes that fall within the prefix (unchanged VM code).
    if (global_pos < ota_prefix_size) {
      uint32_t skip = ota_prefix_size - global_pos;
      if (skip > length - pos) skip = length - pos;
      pos += skip;
      continue;
    }

    // Compute how many bytes to write in this chunk.
    uint32_t to_write = length - pos;

    // Erase flash pages as needed (4KB sectors).
    uint32_t write_end = ota_fota_offset + to_write;
    uint32_t erase_start = ota_fota_offset & ~0xFFF;
    if ((ota_fota_offset & 0xFFF) == 0) {
      // At a page boundary — erase the next page.
      BSP_QSPI_Erase_Safe(erase_start, 0x1000);
    }
    // If write crosses a page boundary, erase the next page too.
    uint32_t next_page = (ota_fota_offset + 0x1000) & ~0xFFF;
    while (next_page < write_end) {
      BSP_QSPI_Erase_Safe(next_page, 0x1000);
      next_page += 0x1000;
    }

    // Write the data.
    if (BSP_QSPI_Write_Safe(
            const_cast<uint8_t*>(data + pos),
            ota_fota_offset,
            to_write) != QSPI_OK) {
      FAIL(HARDWARE_ERROR);
    }

    ota_fota_offset += to_write;
    pos += to_write;
  }

  ota_written += length;

  // Check if the FOTA region has enough space.
  if (ota_fota_offset > FLASH_FOTA_REGION_END) {
    ota_active = false;
    FAIL(OUT_OF_BOUNDS);
  }

  return Smi::from(ota_written);
}

PRIMITIVE(ota_end) {
  ARGS(int, size, Object, expected);
  if (!ota_active) FAIL(ALREADY_CLOSED);

  ota_active = false;

  if (size <= 0) {
    // Caller is just clearing OTA state without committing.
    return process->null_object();
  }

  // The Toit firmware writer reports the total image size it produced.
  // Anything other than the size it announced via ota_begin would indicate
  // a truncated upload.
  if (static_cast<uint32_t>(size) != ota_total_size) FAIL(INVALID_ARGUMENT);
  if (ota_total_size <= ota_prefix_size + Sha::HASH_LENGTH_256) {
    FAIL(INVALID_ARGUMENT);
  }

  // Image layout: [prefix | extension | sha256(image_without_trailer)].
  // The extension landed in FOTA at FLASH_FOTA_REGION_START; the prefix is
  // still in the active image's XIP mapping.
  uint32_t extension_size = ota_total_size - ota_prefix_size;          // incl. trailer
  uint32_t extension_data_size = extension_size - Sha::HASH_LENGTH_256;

  Blob expected_checksum;
  bool has_expected = expected->byte_content(
      process->program(), &expected_checksum, STRINGS_OR_BYTE_ARRAYS);
  if (has_expected && expected_checksum.length() != Sha::HASH_LENGTH_256) {
    FAIL(INVALID_ARGUMENT);
  }

  Sha sha(null, 256);

  // Hash the prefix straight out of XIP — it still holds the running image.
  // AP_FLASH_LOAD_ADDR is the XIP-mapped base.
  const uint8_t* prefix_ptr = reinterpret_cast<const uint8_t*>(AP_FLASH_LOAD_ADDR);
  sha.add(prefix_ptr, ota_prefix_size);

  // Hash the staged extension via a RAM buffer. BSP_QSPI_Read_Safe disables
  // XIP for the duration of the read, so the destination must be in RAM.
  static const uint32_t HASH_BUF_SIZE = 1024;
  uint8_t hash_buf[HASH_BUF_SIZE];
  for (uint32_t off = 0; off < extension_data_size; off += HASH_BUF_SIZE) {
    uint32_t chunk = extension_data_size - off;
    if (chunk > HASH_BUF_SIZE) chunk = HASH_BUF_SIZE;
    if (BSP_QSPI_Read_Safe(hash_buf, FLASH_FOTA_REGION_START + off, chunk) != QSPI_OK) {
      FAIL(HARDWARE_ERROR);
    }
    sha.add(hash_buf, chunk);
  }

  uint8_t computed[Sha::HASH_LENGTH_256];
  sha.get(computed);

  uint8_t stored[Sha::HASH_LENGTH_256];
  if (BSP_QSPI_Read_Safe(stored,
                         FLASH_FOTA_REGION_START + extension_data_size,
                         Sha::HASH_LENGTH_256) != QSPI_OK) {
    FAIL(HARDWARE_ERROR);
  }
  int diff = 0;
  for (int i = 0; i < Sha::HASH_LENGTH_256; i++) diff |= computed[i] ^ stored[i];
  if (diff != 0) FAIL(INVALID_ARGUMENT);

  if (has_expected) {
    diff = 0;
    for (int i = 0; i < Sha::HASH_LENGTH_256; i++) {
      diff |= computed[i] ^ expected_checksum.address()[i];
    }
    if (diff != 0) FAIL(INVALID_ARGUMENT);
  }

  // All checks passed — hand off to the post-shutdown commit step.
  ota_commit_prefix_size = ota_prefix_size;
  ota_commit_extension_size = extension_size;
  ota_updated = true;

  return process->null_object();
}

PRIMITIVE(print_uart_id) {
  // Returns the UART id (0/1/2) the firmware redirects `print` to, or -1
  // if the redirect was disabled at build time. This lets test programs
  // adapt to whichever firmware variant is loaded without rebuilding.
#if CONFIG_TOIT_EC618_PRINT_UART
  return Smi::from(CONFIG_TOIT_EC618_PRINT_UART_ID);
#else
  return Smi::from(-1);
#endif
}

}  // namespace toit

#else  // !TOIT_EC618

#include "objects_inline.h"
#include "primitive.h"
#include "process.h"

namespace toit {

MODULE_IMPLEMENTATION(ec618, MODULE_EC618)

PRIMITIVE(ota_begin) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(ota_write) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(ota_end)   { FAIL(UNIMPLEMENTED); }
PRIMITIVE(print_uart_id) { FAIL(UNIMPLEMENTED); }

}  // namespace toit

#endif  // TOIT_EC618
