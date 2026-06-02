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

#include <stdlib.h>
#include <string.h>

#include "embedded_data.h"
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"
#include "sha.h"
#include "slot_reloc_ec618.h"

extern "C" {
  #include "flash_rt.h"
  #include "mem_map.h"
  #include "slot_marker.h"

  // From ps_lib_api.h. CFUN=0 turns the modem off (RF + PS stack) — the
  // bulk of CP (cellular-processor) activity. The dual-slot OTA turns it
  // off during the flash (the modem_set_function primitive).
  int appSetCFUN(int fun);

  // From the SDK FOTA layer (luat_flash_ctrl_fw_sectors -> this). Must be
  // set (1) around any erase/write into the protected AP-image region;
  // it is the mode the SDK FOTA uses to write firmware there while the
  // system runs (the slot_program_mode primitive).
  void fotaNvmNfsPeInit(unsigned char isSmall);

  // Writable window for flash operations against the AP image, consulted
  // by sysROSpaceCheck (overridden in sys_ro_override.c).
  extern uint32_t toit_ap_image_modify_start;
  extern uint32_t toit_ap_image_modify_end;

  // Linker-script symbols bracketing each VM slot. Declared as arrays so
  // referring to them gives their address.
  extern uint8_t __vm_a_start[];
  extern uint8_t __vm_b_start[];

  // The slot the dispatcher (toit_main.c) actually booted ('A'/'B') — set
  // before the VM runs. This, not the raw marker, is "the slot I run from".
  extern uint8_t toit_booted_slot;
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

// Dual-slot OTA primitives. The current build dispatches between
// .vm_a (slot A) and .vm_b (slot B) based on .slot_marker; these
// primitives let a Toit container receive a new VM image, write it
// into whichever slot isn't currently active, and atomically switch.

// Size of one VM slot, mirrored from the linker script. Bounds-checked
// here so a buggy Toit caller can't run off the end of slot B into the
// marker region (or further into the extension data).
static const uint32_t SLOT_SIZE = 0x60000;

// Returns the VM slot the runtime is currently executing from — 'A' or 'B'
// as ASCII bytes. This is the slot the dispatcher booted, which during a
// trial is the pending slot (not the marker's known-good `active`).
PRIMITIVE(slot_active) {
  return Smi::from(toit_booted_slot);
}

// The slot that is NOT the one we are running from (the OTA target).
static uint8_t inactive_slot() {
  return (toit_booted_slot == 'B') ? 'A' : 'B';
}

// Returns the XIP base address of the inactive slot — where
// slot_inactive_write deposits new bytes.
static uint32_t inactive_slot_base() {
  if (inactive_slot() == 'A') {
    return reinterpret_cast<uint32_t>(__vm_a_start);
  }
  return reinterpret_cast<uint32_t>(__vm_b_start);
}

// Relocate-on-write context. The OTA receiver streams the CANONICAL
// (link-base) image; slot_reloc_begin arms relocation with that image's reloc
// table (the "SRL1" artifact, see src/slot_reloc_ec618.h), and
// slot_inactive_write relocates each chunk onto the destination slot before
// the flash write — so the relocation is invisible to the (architecture-
// agnostic) Toit firmware code. `slot_reloc_delta = dest_slot_base - link_base`
// is 0 when the canonical image lands in slot A (no work) and +/- SLOT_SIZE
// for slot B.
static uint8_t* slot_reloc_blob = null;  // Owned copy of the SRL1 table bytes.
static SlotRelocTable slot_reloc_table;
static int32_t slot_reloc_delta = 0;
static bool slot_reloc_armed = false;

static void slot_reloc_clear() {
  if (slot_reloc_blob != null) {
    free(slot_reloc_blob);
    slot_reloc_blob = null;
  }
  slot_reloc_armed = false;
  slot_reloc_delta = 0;
}

// Arm relocate-on-write with the new image's reloc table. The table is copied
// (the Blob is transient) and parsed; the destination-slot displacement is
// derived from the table's link base. While armed, slot_inactive_write
// relocates the canonical bytes it is given onto the inactive slot.
PRIMITIVE(slot_reloc_begin) {
  // See slot_inactive_erase about PRIVILEGED.
  ARGS(Blob, table);
  slot_reloc_clear();
  int length = table.length();
  uint8_t* copy = unvoid_cast<uint8_t*>(malloc(length));
  if (copy == null) FAIL(MALLOC_FAILED);
  memcpy(copy, table.address(), length);
  if (!slot_reloc_parse(copy, length, &slot_reloc_table)) {
    free(copy);
    FAIL(INVALID_ARGUMENT);
  }
  const uint32_t dest_base = inactive_slot_base();
  slot_reloc_delta = static_cast<int32_t>(dest_base) -
                     static_cast<int32_t>(slot_reloc_table.link_base);
  slot_reloc_blob = copy;
  slot_reloc_armed = true;
  return process->null_object();
}

// Disarm relocate-on-write and release the table. Idempotent.
PRIMITIVE(slot_reloc_end) {
  slot_reloc_clear();
  return process->null_object();
}

// Erase a single 4 KB sector inside the inactive slot. Caller passes
// the sector's offset within the slot (must be sector-aligned). The
// host walks the slot one sector at a time so each call returns
// quickly enough to keep the PLAT watchdog from firing — a
// whole-slot erase would block ~7 s and reset the chip.
PRIMITIVE(slot_inactive_erase) {
  // Not PRIVILEGED while the dual-slot OTA receiver is a regular app
  // container. Lock down once the OTA path moves into the system
  // process (firmware service).
  ARGS(int, offset);
  if (offset < 0 || (offset % FLASH_SECTOR_SIZE) != 0) FAIL(INVALID_ARGUMENT);
  if (static_cast<uint32_t>(offset) >= SLOT_SIZE) FAIL(OUT_OF_BOUNDS);

  const uint32_t base_xip = inactive_slot_base();
  const uint32_t base_phys = base_xip - AP_FLASH_XIP_ADDR;
  const uint32_t dest = base_phys + static_cast<uint32_t>(offset);

  uint32_t saved_start = toit_ap_image_modify_start;
  uint32_t saved_end = toit_ap_image_modify_end;
  toit_ap_image_modify_start = base_phys;
  toit_ap_image_modify_end = base_phys + SLOT_SIZE;

  int rc = BSP_QSPI_Erase_Safe(dest, FLASH_SECTOR_SIZE);

  toit_ap_image_modify_start = saved_start;
  toit_ap_image_modify_end = saved_end;

  if (rc != QSPI_OK) {
    printf("[toit] ERROR: slot erase failed at 0x%08x rc=%d\n",
           static_cast<unsigned>(dest), rc);
    FAIL(QUOTA_EXCEEDED);
  }
  return process->null_object();
}

// Write `bytes` to the inactive slot at `offset`. Caller is responsible
// for `slot_inactive_erase` first and for keeping offset + length within
// SLOT_SIZE. Length must be a multiple of FLASH_SEGMENT_SIZE (16 B) —
// BSP_QSPI_Write_Safe requires segment-aligned writes.
PRIMITIVE(slot_inactive_write) {
  // See slot_inactive_erase about PRIVILEGED.
  ARGS(int, offset, Blob, bytes);

  if (offset < 0) FAIL(INVALID_ARGUMENT);
  if (bytes.length() % FLASH_SEGMENT_SIZE != 0) FAIL(INVALID_ARGUMENT);
  const uint32_t off = static_cast<uint32_t>(offset);
  if (off % FLASH_SEGMENT_SIZE != 0) FAIL(INVALID_ARGUMENT);
  if (off > SLOT_SIZE || bytes.length() > SLOT_SIZE - off) FAIL(OUT_OF_BOUNDS);

  const uint32_t base_xip = inactive_slot_base();
  const uint32_t base_phys = base_xip - AP_FLASH_XIP_ADDR;
  const uint32_t dest = base_phys + off;

  // When relocate-on-write is armed (and the destination is not the link
  // slot), relocate the canonical bytes onto the destination slot in a RAM
  // scratch copy before writing — NOR flash is written once per erase, so the
  // bytes must already be relocated when the sector is programmed. The
  // receiver writes sector-sized, sector-aligned chunks, so no reloc patch
  // site straddles a chunk boundary; slot_reloc_apply rejects a straddle.
  const uint8_t* source = bytes.address();
  uint8_t* relocated = null;
  if (slot_reloc_armed && slot_reloc_delta != 0) {
    relocated = unvoid_cast<uint8_t*>(malloc(bytes.length()));
    if (relocated == null) FAIL(MALLOC_FAILED);
    memcpy(relocated, bytes.address(), bytes.length());
    if (!slot_reloc_apply(&slot_reloc_table, relocated, off, bytes.length(),
                          slot_reloc_delta, SLOT_RELOC_TO_SLOT)) {
      free(relocated);
      FAIL(INVALID_ARGUMENT);
    }
    source = relocated;
  }

  uint32_t saved_start = toit_ap_image_modify_start;
  uint32_t saved_end = toit_ap_image_modify_end;
  toit_ap_image_modify_start = base_phys;
  toit_ap_image_modify_end = base_phys + SLOT_SIZE;

  // BSP_QSPI_Write_Safe disables XIP for the duration of the call. The
  // source must live in RAM — both Blob::address() (a process-heap pointer)
  // and the relocation scratch are in MSMB RAM.
  int rc = BSP_QSPI_Write_Safe(
      const_cast<uint8_t*>(source), dest, bytes.length());

  toit_ap_image_modify_start = saved_start;
  toit_ap_image_modify_end = saved_end;

  if (relocated != null) free(relocated);

  if (rc != QSPI_OK) {
    printf("[toit] ERROR: slot write failed at 0x%08x rc=%d\n",
           static_cast<unsigned>(dest), rc);
    FAIL(QUOTA_EXCEEDED);
  }
  return process->null_object();
}

// Triggers a system reset; does not return. Drains the print FIFO first so
// the preceding status line reaches the wire.
[[noreturn]] static void ec618_system_reset() {
  for (volatile uint32_t i = 0; i < 200000; i++) { /* spin */ }
  // SCB->AIRCR: VECTKEY (0x05FA << 16) | SYSRESETREQ (bit 2).
  volatile uint32_t* const SCB_AIRCR = reinterpret_cast<uint32_t*>(0xE000ED0C);
  *SCB_AIRCR = (0x05FAu << 16) | (1u << 2);
  while (1) { /* unreachable */ }
}

// Stage the freshly-written inactive slot as a trial and reset into it. The
// known-good `active` is left as the slot we are running from; only a later
// slot_mark_valid promotes the trial. On the next boot the dispatcher
// (toit_main.c) consumes the trial (NEW -> PENDING_VERIFY) before running
// the new VM, so a crash loop automatically rolls back.
//
// Assumes the caller already holds firmware program/erase mode (the OTA
// receiver enables it around the slot erase/write, exactly like the slot_*
// flash primitives above). Returns only if the marker write fails.
PRIMITIVE(slot_stage_and_reset) {
  // See slot_inactive_erase about PRIVILEGED.
  if (!slot_marker_write(toit_booted_slot, inactive_slot(), SLOT_STATE_NEW)) {
    printf("[toit] ERROR: slot stage (marker write) failed\n");
    FAIL(QUOTA_EXCEEDED);
  }
  printf("[toit] INFO: staged slot %c for trial — rebooting\n", inactive_slot());
  ec618_system_reset();
}

// Confirm the slot we are running from: promote it to the known-good
// `active` and clear the trial. Cancels the automatic rollback. Returns
// normally (no reset). Self-brackets program/erase mode because it is
// called during normal operation, not inside the OTA flash flow.
PRIMITIVE(slot_mark_valid) {
  // See slot_inactive_erase about PRIVILEGED.
  fotaNvmNfsPeInit(1);
  bool ok = slot_marker_write(toit_booted_slot, 0, SLOT_STATE_NONE);
  fotaNvmNfsPeInit(0);
  if (!ok) {
    printf("[toit] ERROR: slot validate (marker write) failed\n");
    FAIL(QUOTA_EXCEEDED);
  }
  printf("[toit] INFO: slot %c validated\n", toit_booted_slot);
  return process->null_object();
}

// Reject the slot we are running from and reset back to the known-good
// slot (esp-idf's mark_app_invalid_rollback_and_reboot). Reads the record
// to learn which slot is the known-good `active` to fall back to. Returns
// only if the marker write fails.
PRIMITIVE(slot_mark_invalid_and_reset) {
  // See slot_inactive_erase about PRIVILEGED.
  slot_record rec;
  slot_marker_read(&rec);
  // If we are the pending trial, fall back to the record's active; otherwise
  // (already the active slot) there is nothing to roll back to but the
  // other slot, so target it.
  uint8_t fallback = (rec.pending == toit_booted_slot) ? rec.active : inactive_slot();

  fotaNvmNfsPeInit(1);
  bool ok = slot_marker_write(fallback, 0, SLOT_STATE_NONE);
  fotaNvmNfsPeInit(0);
  if (!ok) {
    printf("[toit] ERROR: slot invalidate (marker write) failed\n");
    FAIL(QUOTA_EXCEEDED);
  }
  printf("[toit] INFO: slot %c rejected — rolling back to %c\n",
         toit_booted_slot, fallback);
  ec618_system_reset();
}

// True if the slot we are running from is an unconfirmed trial — i.e. the
// dispatcher booted it as `pending` and it is awaiting validation. The app
// uses this to know it must call slot_mark_valid (or it will roll back on
// the next reset).
PRIMITIVE(slot_trial) {
  slot_record rec;
  slot_marker_read(&rec);
  bool trial = (rec.pending != 0) && (rec.pending == toit_booted_slot);
  return BOOL(trial);
}

// Enter (on != 0) or leave the SDK's firmware-sector program/erase mode
// (fotaNvmNfsPeInit / luat_flash_ctrl_fw_sectors). REQUIRED around any
// erase/write into the protected AP-image region (the inactive slot):
// without it those ops disrupt the CP and reset the chip almost
// immediately. The SDK's own FOTA sets this before writing firmware into
// that region.
PRIMITIVE(slot_program_mode) {
  ARGS(int, on);
  fotaNvmNfsPeInit(on ? 1 : 0);
  return process->null_object();
}

// Set modem functionality via appSetCFUN (0 = off). The dual-slot OTA
// turns the modem off for the duration of the flash, because sustained
// AP flash+UART activity with the modem on resets the chip after a few
// seconds (a CP real-time deadline — see docs/ota-dual-slot-plan.md).
// Returns the SDK result code.
PRIMITIVE(modem_set_function) {
  ARGS(int, fun);
  return Smi::from(appSetCFUN(fun));
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
PRIMITIVE(slot_active) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_inactive_erase) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_inactive_write) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_reloc_begin) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_reloc_end) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_stage_and_reset) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_mark_valid) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_mark_invalid_and_reset) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_trial) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_program_mode) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(modem_set_function) { FAIL(UNIMPLEMENTED); }

}  // namespace toit

#endif  // TOIT_EC618
