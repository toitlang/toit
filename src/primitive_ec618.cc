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

// Global flag checked by toit_ec618.cc after VM shutdown.
bool ota_updated = false;

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
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  if (extension == null) FAIL(ERROR);
  uint32_t extension_addr = reinterpret_cast<uint32_t>(extension);
  uint32_t image_start = AP_FLASH_XIP_ADDR + AP_FLASH_LOAD_ADDR;
  ota_prefix_size = extension_addr - image_start;

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
  USE(expected);
  if (!ota_active) FAIL(ALREADY_CLOSED);

  ota_active = false;

  if (size > 0) {
    // Signal to toit_ec618.cc that an OTA update was staged.
    ota_updated = true;
  }

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
