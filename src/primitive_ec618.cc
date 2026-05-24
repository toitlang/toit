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

#include <string.h>

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
// copies it into the active image area after VM shutdown.
//
// The firmware image has a prefix (VM + system code, from AP_FLASH_LOAD_ADDR
// to the embedded data extension) that is identical between the old and new
// firmware. Only the extension data (snapshots, config, SHA-256 trailer)
// changes, so ota_write skips the prefix and writes only the changed tail
// into the FOTA region.
//
// FLASH_SEGMENT_SIZE (from flash_allocation.h) is the QSPI controller's
// minimum write unit. Every write to flash is rounded up to a multiple of
// this many bytes, padding the last 0..15 bytes of the staged image with
// zeros.
static const uint32_t FLASH_SECTOR_SIZE = 0x1000;

// Set by ota_end after a successful SHA-256 verification, consumed by the
// post-shutdown commit step in toit_ec618.cc.
bool ota_updated = false;
uint32_t ota_commit_size = 0;  // Total firmware size to copy from FOTA to AP image.

// All other OTA bookkeeping is derived from ota_written each time it is
// needed, so there is a single source of truth for "how far along we are".
static bool ota_active = false;
static uint32_t ota_written = 0;     // Logical bytes seen by ota_write so far.
static uint32_t ota_total_size = 0;  // Image size declared via ota_begin.

// Set once the caller submits a non-segment-aligned chunk to ota_write; that
// chunk must be the very last one. Any subsequent write is rejected.
static bool ota_unaligned_tail_seen = false;

// Lazy sector erase: bytes in [FLASH_FOTA_REGION_START, ota_erased_until)
// are guaranteed to be in the erased (0xff) state. Always sector-aligned.
static uint32_t ota_erased_until = 0;

// The tool pads the AP binary up to FLASH_SECTOR_SIZE before appending the
// extension, so the prefix size is always sector-aligned (and therefore
// segment-aligned). FOTA reads/writes only make sense when the staging
// region is sector-aligned to begin with.
static_assert(FLASH_FOTA_REGION_START % FLASH_SECTOR_SIZE == 0,
              "FOTA region must start at a sector boundary");
static_assert(FLASH_SECTOR_SIZE % FLASH_SEGMENT_SIZE == 0,
              "sector size must be a multiple of segment size");

MODULE_IMPLEMENTATION(ec618, MODULE_EC618)

// The unchanged-prefix length is the offset from the start of the active
// image to the embedded data extension. We recompute it each time so we do
// not have to keep it in sync with ota_written.
static uint32_t ota_prefix_size() {
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  return reinterpret_cast<uint32_t>(extension) - AP_FLASH_LOAD_ADDR;
}

// Map a logical image position into the staging FOTA region. Only valid
// once we are past the unchanged prefix; the caller must check first.
static uint32_t fota_offset_for(uint32_t global_pos, uint32_t prefix) {
  return FLASH_FOTA_REGION_START + (global_pos - prefix);
}

PRIMITIVE(ota_begin) {
  PRIVILEGED;
  ARGS(int, from, int, to);
  if (ota_active) FAIL(ALREADY_IN_USE);
  if (from < 0 || to <= from) FAIL(INVALID_ARGUMENT);

  // We need the embedded data extension to be reachable so that
  // ota_prefix_size() can find the AP-image/extension boundary.
  if (EmbeddedData::extension() == null) FAIL(ERROR);

  const uint32_t total = static_cast<uint32_t>(to - from);
  const uint32_t prefix = ota_prefix_size();
  // The tool pads the AP binary to a sector boundary; if the running image
  // doesn't satisfy that, our segment-alignment assumptions break.
  if (prefix % FLASH_SECTOR_SIZE != 0) FAIL(ERROR);
  // The extension (post-prefix) is everything we'll stage into FOTA, and
  // FOTA has a hard size cap. ota_end will also pad the unaligned tail up
  // to a full segment, so include that in the bound.
  if (total <= prefix) FAIL(INVALID_ARGUMENT);
  const uint32_t staged_aligned =
      ((total - prefix) + FLASH_SEGMENT_SIZE - 1) & ~(FLASH_SEGMENT_SIZE - 1);
  if (staged_aligned > FLASH_FOTA_REGION_LEN) FAIL(OUT_OF_BOUNDS);

  ota_total_size = total;
  ota_written = 0;
  ota_erased_until = FLASH_FOTA_REGION_START;
  ota_unaligned_tail_seen = false;
  ota_active = true;
  return process->null_object();
}

// Erase whichever 4 KB sectors are needed so that
// [FLASH_FOTA_REGION_START, target) is fully erased. Sectors are erased at
// most once. Returns false on QSPI error.
static bool ota_ensure_erased_until(uint32_t target) {
  while (ota_erased_until < target) {
    if (BSP_QSPI_Erase_Safe(ota_erased_until, FLASH_SECTOR_SIZE) != QSPI_OK) {
      return false;
    }
    ota_erased_until += FLASH_SECTOR_SIZE;
  }
  return true;
}

PRIMITIVE(ota_write) {
  PRIVILEGED;
  ARGS(Blob, bytes);
  if (!ota_active) FAIL(ALREADY_CLOSED);
  // Once a sub-segment tail has been accepted, no further data may come.
  if (ota_unaligned_tail_seen) FAIL(ALREADY_CLOSED);

  const uint8_t* data = bytes.address();
  const uint32_t length = bytes.length();

  // Reject anything that would push us past the size declared in ota_begin.
  if (length > ota_total_size - ota_written) {
    ota_active = false;
    FAIL(OUT_OF_BOUNDS);
  }

  const uint32_t prefix = ota_prefix_size();
  // ota_begin validated that prefix is sector-aligned (and therefore segment-
  // aligned). The Toit-side writer flushes in PAGE_SIZE-aligned chunks until
  // the final remainder in commit, so chunks straddling the prefix boundary
  // are also segment-aligned on both sides.
  uint32_t pos = 0;
  if (ota_written + pos < prefix) {
    uint32_t skip = prefix - (ota_written + pos);
    if (skip > length - pos) skip = length - pos;
    pos += skip;
  }

  // Everything from here on is extension data that has to land in FOTA.
  uint32_t fota_offset = fota_offset_for(ota_written + pos, prefix);
  const uint32_t payload = length - pos;

  // Non-final chunks must be segment-aligned in length; the only exception
  // is the very last tail (after which ota_end fires). Detect it here and
  // latch the flag so subsequent calls are rejected.
  if (payload % FLASH_SEGMENT_SIZE != 0) {
    if (ota_written + length != ota_total_size) {
      ota_active = false;
      FAIL(INVALID_ARGUMENT);
    }
    ota_unaligned_tail_seen = true;
  }

  // Write segment-aligned bytes straight through. We stage via a RAM segment
  // because the source may be external (e.g. firmware.map proxy into XIP)
  // and BSP_QSPI_Write_Safe disables XIP for the duration of the call.
  const uint32_t segment_count = payload / FLASH_SEGMENT_SIZE;
  uint8_t segment[FLASH_SEGMENT_SIZE];
  for (uint32_t i = 0; i < segment_count; i++) {
    memcpy(segment, data + pos, FLASH_SEGMENT_SIZE);
    if (!ota_ensure_erased_until(fota_offset + FLASH_SEGMENT_SIZE)) {
      ota_active = false;
      FAIL(HARDWARE_ERROR);
    }
    if (BSP_QSPI_Write_Safe(segment, fota_offset, FLASH_SEGMENT_SIZE) != QSPI_OK) {
      ota_active = false;
      FAIL(HARDWARE_ERROR);
    }
    pos += FLASH_SEGMENT_SIZE;
    fota_offset += FLASH_SEGMENT_SIZE;
  }

  // Sub-segment tail (only reachable on the very last call): zero-pad and
  // write as a final segment.
  const uint32_t tail = length - pos;
  if (tail > 0) {
    memset(segment, 0, FLASH_SEGMENT_SIZE);
    memcpy(segment, data + pos, tail);
    if (!ota_ensure_erased_until(fota_offset + FLASH_SEGMENT_SIZE)) {
      ota_active = false;
      FAIL(HARDWARE_ERROR);
    }
    if (BSP_QSPI_Write_Safe(segment, fota_offset, FLASH_SEGMENT_SIZE) != QSPI_OK) {
      ota_active = false;
      FAIL(HARDWARE_ERROR);
    }
  }

  ota_written += length;
  return Smi::from(ota_written);
}

PRIMITIVE(ota_end) {
  PRIVILEGED;
  ARGS(int, size, Object, expected);
  if (!ota_active) FAIL(ALREADY_CLOSED);

  ota_active = false;

  if (size <= 0) {
    // Caller is just clearing OTA state without committing.
    return process->null_object();
  }

  // The Toit firmware writer reports the total image size it produced.
  // Anything other than the size announced via ota_begin would indicate a
  // truncated upload (the bounds check in ota_write would have already
  // rejected an over-long one).
  if (static_cast<uint32_t>(size) != ota_total_size) FAIL(INVALID_ARGUMENT);

  const uint32_t prefix = ota_prefix_size();
  if (ota_total_size <= prefix + Sha::HASH_LENGTH_256) FAIL(INVALID_ARGUMENT);

  // Image layout: [prefix | extension | sha256(image_without_trailer)].
  // The extension landed in the FOTA region; the prefix is still in the
  // active image's XIP mapping. The extension data ends 32 bytes before
  // the trailer.
  const uint32_t extension_data_size =
      ota_total_size - prefix - Sha::HASH_LENGTH_256;

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
  sha.add(prefix_ptr, prefix);

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
  ota_commit_size = ota_total_size;
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
