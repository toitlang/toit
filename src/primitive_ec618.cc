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
#include "resources/pad_table_ec618.h"
#include "process.h"
#include "sha.h"
#include "slot_reloc_ec618.h"

extern "C" {
  #include "flash_rt.h"
  #include "mem_map.h"
  #include "slot_marker.h"
  #include "toit_partitions.h"  // Generated from toolchains/ec618/partitions.yaml.
  #include "reset.h"  // ResetStateGet / LastResetState_e.
  #include "wdt.h"    // The WDT module — the watchdog's busy-lockup backstop.

  // From slpman (jump-tabled): live AON wakeup-pad levels, and the latched
  // wakeup source of the most recent boot (slpManWakeSrc_e).
  uint32_t slpManGetWakeupPinValue(void);
  int slpManGetWakeupSrc(void);
  #include "clock.h"  // GPR_setClock* for the WDT functional clock.
  #include "FreeRTOS.h"
  #include "task.h"        // xTaskCreate — the software-watchdog task.
  #include "cmsis_os2.h"   // osDelay / osKernelGetTickCount.

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

// FLASH_SECTOR_SIZE is the QSPI controller's 4 KB erase unit; FLASH_SEGMENT_SIZE
// (from flash_allocation.h) is its minimum write unit. The dual-slot OTA
// primitives align their erases and writes to these.
static const uint32_t FLASH_SECTOR_SIZE = 0x1000;
static_assert(FLASH_SECTOR_SIZE % FLASH_SEGMENT_SIZE == 0,
              "sector size must be a multiple of segment size");

// XIP address of the base-id record: { 'T','B','I','1', version:u32 LE,
// fingerprint:16 } — stamped by tools/ec618/gen-base-id.toit into the
// `base-id` partition (toolchains/ec618/partitions.yaml).
static const uintptr_t BASE_ID_XIP = TOIT_PART_BASE_ID_XIP;

MODULE_IMPLEMENTATION(ec618, MODULE_EC618)

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
static const uint32_t SLOT_SIZE = TOIT_PART_SLOT_SIZE;  // From partitions.yaml.

// Returns the VM slot the runtime is currently executing from — 'A' or 'B'
// as ASCII bytes. This is the slot the dispatcher booted, which during a
// trial is the pending slot (not the marker's known-good `active`).
PRIMITIVE(slot_active) {
  return Smi::from(toit_booted_slot);
}

// Returns the slot size of the layout this firmware was built for, so the
// Toit side never carries its own copy of the geometry. Once the active
// table lives in the marker record (v2), this reads that instead.
PRIMITIVE(slot_size) {
  return Smi::from(SLOT_SIZE);
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

// Returns the XIP base address of the slot the runtime booted from.
static uint32_t active_slot_base() {
  return (toit_booted_slot == 'B') ? reinterpret_cast<uint32_t>(__vm_b_start)
                                   : reinterpret_cast<uint32_t>(__vm_a_start);
}

// Active-slot canonical firmware view (convergence #3 read path). firmware.map
// presents the running slot as its CANONICAL image (table-first, un-relocated)
// through SlotFirmware, so the integrity SHA and delta-OTA see the same bytes
// regardless of which slot is live. The helpers below back the firmware_map /
// firmware_mapping_at / firmware_mapping_copy core primitives
// (src/primitive_core.cc) on the EC618 target. The view borrows the slot's XIP
// bytes, which stay mapped, so it survives between calls.
static SlotFirmware g_active_firmware;

// Opens the view over the running slot and returns its canonical size (0 on
// failure). `*base_out` receives the slot's XIP base, used only so the firmware
// proxy carries a valid (if unread) external address.
uint32_t ec618_active_firmware_open(uint8_t** base_out) {
  uint32_t base = active_slot_base();
  *base_out = reinterpret_cast<uint8_t*>(base);
  if (!g_active_firmware.open(reinterpret_cast<const uint8_t*>(base), base, SLOT_SIZE)) {
    return 0;
  }
  return g_active_firmware.canonical_size();
}

// Reads one canonical byte. `index` is already absolute (offset + local index).
uint8_t ec618_active_firmware_at(uint32_t index) {
  return g_active_firmware.at(index);
}

// Copies canonical bytes [from, to) into `dest`. Returns whether it succeeded
// (false on a misaligned body window — the caller copies word-aligned blocks).
bool ec618_active_firmware_copy(uint32_t from, uint32_t to, uint8_t* dest) {
  return g_active_firmware.copy(from, to, dest);
}

// Relocate-on-write context. The OTA receiver streams the CANONICAL
// (link-base) image; slot_reloc_begin arms relocation with that image's reloc
// table (the "SRL2" artifact, see src/slot_reloc_ec618.h), and
// slot_inactive_write relocates each chunk onto the destination slot before
// the flash write — so the relocation is invisible to the (architecture-
// agnostic) Toit firmware code. `slot_reloc_delta = dest_slot_base - link_base`
// is 0 when the canonical image lands in slot A (no work) and +/- SLOT_SIZE
// for slot B.
static uint8_t* slot_reloc_blob = null;  // Owned copy of the SRL2 table bytes.
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

// Arm relocate-on-write with the new image's reloc table, and lay that table
// down as the inactive slot's tail trailer. The table is copied (the Blob is
// transient) and parsed; the destination-slot displacement is derived from the
// table's link base. While armed, slot_inactive_write relocates the canonical
// bytes it is given onto the inactive slot.
//
// The trailer (`[ table ][ size : last word ]`, see src/slot_reloc_ec618.h)
// goes at the very tail so the image, once it boots as the active slot, can
// recover its own table to un-relocate reads. The caller must be holding
// program mode (same as slot_inactive_write); the trailer's tail sectors are
// erased here, so the caller does NOT erase them.
//
// OTA write ordering: the body is written front-to-back AFTER this call, with a
// lazy per-sector erase. To keep that erase from clobbering the trailer, the
// body and the trailer must live in DISJOINT flash sectors — enforced below.
PRIMITIVE(slot_reloc_begin) {
  PRIVILEGED;
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

  // Base-id gate (frozen-base phase 4): the incoming image's SRL3 table
  // carries the base it was linked against; refuse it if that is not the
  // base THIS device runs — a mismatched slot would branch to addresses the
  // flashed base does not have, an undebuggable fault. The device's own
  // record is stamped by gen-base-id.toit into the reserved flash page.
  {
    const uint8_t* record = reinterpret_cast<const uint8_t*>(BASE_ID_XIP);
    bool device_ok = record[0] == 'T' && record[1] == 'B' &&
                     record[2] == 'I' && record[3] == '1';
    uint32_t device_version = device_ok
        ? (record[4] | (record[5] << 8) | (record[6] << 16) |
           (static_cast<uint32_t>(record[7]) << 24))
        : 0;
    bool match = device_ok && device_version == slot_reloc_table.base_version &&
                 memcmp(record + 8, slot_reloc_table.base_fp, 16) == 0;
    if (!match) {
      printf("[toit] ERROR: base mismatch — image built for base-v%u, "
             "device runs base-v%u%s; full-flash the matching base\n",
             static_cast<unsigned>(slot_reloc_table.base_version),
             static_cast<unsigned>(device_version),
             device_ok ? "" : " (no base-id record)");
      free(copy);
      FAIL(OUT_OF_BOUNDS);
    }
  }

  const uint32_t dest_base = inactive_slot_base();
  slot_reloc_delta = static_cast<int32_t>(dest_base) -
                     static_cast<int32_t>(slot_reloc_table.link_base);

  // The trailer is one segment-aligned block ending at the slot's last byte
  // (so the size word is the slot's last word). Its sectors must not overlap
  // the body's sectors, since the body's lazy erase would otherwise erase the
  // trailer that this call writes.
  const uint32_t block_size = (static_cast<uint32_t>(length) + 4 +
                               FLASH_SEGMENT_SIZE - 1) & ~(FLASH_SEGMENT_SIZE - 1);
  if (block_size > SLOT_SIZE) { free(copy); FAIL(OUT_OF_BOUNDS); }
  const uint32_t trailer_first_sector =
      (SLOT_SIZE - block_size) & ~(FLASH_SECTOR_SIZE - 1);
  // The populated front is body + extension (body_size) PLUS the verbatim VM
  // .data init image that rides after it (data_size) — both are streamed
  // front-to-back with a lazy per-sector erase, so the whole front must clear
  // the trailer's sectors.
  const uint32_t front = slot_reloc_table.body_size + slot_reloc_table.data_size;
  const uint32_t front_sectors_end =
      (front + FLASH_SECTOR_SIZE - 1) & ~(FLASH_SECTOR_SIZE - 1);
  if (front_sectors_end > trailer_first_sector) {
    free(copy);
    FAIL(OUT_OF_BOUNDS);  // Body + .data and trailer would share a sector.
  }
  uint8_t* block = unvoid_cast<uint8_t*>(malloc(block_size));
  if (block == null) { free(copy); FAIL(MALLOC_FAILED); }
  if (!slot_reloc_build_trailer(copy, length, block, block_size)) {
    free(block);
    free(copy);
    FAIL(INVALID_ARGUMENT);
  }
  const uint32_t base_phys = dest_base - AP_FLASH_XIP_ADDR;
  uint32_t saved_start = toit_ap_image_modify_start;
  uint32_t saved_end = toit_ap_image_modify_end;
  toit_ap_image_modify_start = base_phys;
  toit_ap_image_modify_end = base_phys + SLOT_SIZE;
  // Erase the trailer's sectors, then write the block into them.
  int rc = QSPI_OK;
  for (uint32_t s = trailer_first_sector; s < SLOT_SIZE; s += FLASH_SECTOR_SIZE) {
    rc = BSP_QSPI_Erase_Safe(base_phys + s, FLASH_SECTOR_SIZE);
    if (rc != QSPI_OK) break;
  }
  if (rc == QSPI_OK) {
    rc = BSP_QSPI_Write_Safe(block, base_phys + SLOT_SIZE - block_size, block_size);
  }
  toit_ap_image_modify_start = saved_start;
  toit_ap_image_modify_end = saved_end;
  free(block);
  if (rc != QSPI_OK) {
    free(copy);
    printf("[toit] ERROR: slot trailer write failed rc=%d\n", rc);
    FAIL(QUOTA_EXCEEDED);
  }

  slot_reloc_blob = copy;
  slot_reloc_armed = true;
  return process->null_object();
}

// Disarm relocate-on-write and release the table. Idempotent.
PRIMITIVE(slot_reloc_end) {
  PRIVILEGED;
  slot_reloc_clear();
  return process->null_object();
}

// Erase a single 4 KB sector inside the inactive slot. Caller passes
// the sector's offset within the slot (must be sector-aligned). The
// host walks the slot one sector at a time so each call returns
// quickly enough to keep the PLAT watchdog from firing — a
// whole-slot erase would block ~7 s and reset the chip.
PRIMITIVE(slot_inactive_erase) {
  PRIVILEGED;  // The OTA writer runs in the system (firmware service) process.
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
  PRIVILEGED;
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
[[noreturn]] void ec618_system_reset() {
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
  PRIVILEGED;
  if (!slot_marker_write(toit_booted_slot, inactive_slot(), SLOT_STATE_NEW)) {
    printf("[toit] ERROR: slot stage (marker write) failed\n");
    FAIL(QUOTA_EXCEEDED);
  }
  printf("[toit] INFO: staged slot %c for trial — rebooting\n", inactive_slot());
  ec618_system_reset();
}

// Stage the freshly-written inactive slot as a trial WITHOUT resetting. The
// standard FirmwareWriter.commit calls this; the reboot into the trial happens
// later, when the system calls firmware.upgrade. Same marker write as
// slot_stage_and_reset, minus the reset. Returns normally.
PRIMITIVE(slot_stage) {
  PRIVILEGED;
  if (!slot_marker_write(toit_booted_slot, inactive_slot(), SLOT_STATE_NEW)) {
    printf("[toit] ERROR: slot stage (marker write) failed\n");
    FAIL(QUOTA_EXCEEDED);
  }
  printf("[toit] INFO: staged slot %c for trial\n", inactive_slot());
  return process->null_object();
}

// Confirm the slot we are running from: promote it to the known-good
// `active` and clear the trial. Cancels the automatic rollback. Returns
// normally (no reset). Self-brackets program/erase mode because it is
// called during normal operation, not inside the OTA flash flow.
PRIMITIVE(slot_mark_valid) {
  PRIVILEGED;
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
  PRIVILEGED;
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
  PRIVILEGED;
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

PRIMITIVE(wakeup_pin_values) {
  // Live levels of the AON wakeup pads (WAKEUP_PAD0.. as a bitmask) — the
  // AON-domain pads are not readable through the plain GPIO controller.
  return Primitive::integer(slpManGetWakeupPinValue(), process);
}

// Returns the AP-side reset reason of the most recent boot as a
// LastResetState_e value (see lib/ec618 reset-reason constants). The CP
// reset reason is read but not surfaced; the AP value is what application
// code reacts to (e.g. distinguishing a watchdog reset from a power-on).
PRIMITIVE(reset_reason) {
  LastResetState_e ap = LAST_RESET_UNKNOWN;
  LastResetState_e cp = LAST_RESET_UNKNOWN;
  ResetStateGet(&ap, &cp);
  return Smi::from(ap);
}

// The sleep manager's wake-source latch (slpManGetWakeupSrc) reads correctly
// only very early in boot: the sleep-manager re-init in start() resets it to
// POR before application code can read it (HW-verified — an early read returns
// RTC after a timer wake, a late read returns POR). start() snapshots it once
// via toit_capture_boot_wakeup_src(); the primitive serves the snapshot.
static int boot_wakeup_src_ = 0;  // WAKEUP_FROM_POR until captured at boot.
extern "C" int toit_capture_boot_wakeup_src() {
  boot_wakeup_src_ = slpManGetWakeupSrc();
  return boot_wakeup_src_;
}

// Returns what woke the chip at the most recent boot as a slpManWakeSrc_e
// value (see lib/ec618 WAKEUP-* constants). The AP reset reason reads
// power-on even after a hibernate wake (HW-verified), so this is the call
// that tells a deep-sleep wake (RTC timer / wakeup pad) apart from a cold
// boot.
PRIMITIVE(wakeup_cause) {
  return Smi::from(boot_wakeup_src_);
}

// Deep-sleep wakeup-pad configuration. The primitives only record what to
// arm; the deep-sleep path (toit_ec618.cc arm_wakeup_pads) applies it at VM
// exit, right before hibernate entry — an armed pad then wakes the chip
// (which reboots; ec618.wakeup-cause reads WAKEUP_FROM_PAD). Zero-initialized
// statics live in .bss, so this state is OTA-slot-safe.
//
// Packed per-pad config: bit 0 enabled, bit 1 posEdge, bit 2 negEdge,
// bit 3 pullUp, bit 4 pullDown.
static const int kWakeupPadCount = 6;
static uint8_t wakeup_pad_configs_[kWakeupPadCount];
static int wakeup_arm_flags_ = 0;

extern "C" int toit_wakeup_pad_config(int pad) {
  if (pad < 0 || pad >= kWakeupPadCount) return 0;
  return wakeup_pad_configs_[pad];
}

extern "C" int toit_wakeup_arm_flags() {
  return wakeup_arm_flags_;
}

PRIMITIVE(wakeup_pad_configure) {
  ARGS(int, pad, bool, enabled, bool, pos_edge, bool, neg_edge,
       bool, pull_up, bool, pull_down);
  if (pad < 0 || pad >= kWakeupPadCount) FAIL(OUT_OF_RANGE);
  uint8_t packed = 0;
  if (enabled) packed |= 1;
  if (pos_edge) packed |= 2;
  if (neg_edge) packed |= 4;
  if (pull_up) packed |= 8;
  if (pull_down) packed |= 16;
  wakeup_pad_configs_[pad] = packed;
  return process->null_object();
}

// Bring-up diagnostic: selects arming-sequence variants (see
// toit_ec618.cc arm_wakeup_pads for the bit meanings) so the wake
// sequence can be A/B-tested from a test container without reflashing.
PRIMITIVE(wakeup_arm_flags) {
  ARGS(int, flags);
  wakeup_arm_flags_ = flags;
  return process->null_object();
}

// Returns the flashed base's identity as "base-v<N>+<fingerprint hex>", or
// "base-unknown" when the reserved page carries no record (a pre-phase-4
// base). Slot OTAs are accepted only when the incoming image's SRL3 table
// matches this id (see slot_reloc_begin).
PRIMITIVE(base_id) {
  const uint8_t* record = reinterpret_cast<const uint8_t*>(BASE_ID_XIP);
  if (!(record[0] == 'T' && record[1] == 'B' &&
        record[2] == 'I' && record[3] == '1')) {
    return process->allocate_string_or_error("base-unknown");
  }
  uint32_t version = record[4] | (record[5] << 8) | (record[6] << 16) |
                     (static_cast<uint32_t>(record[7]) << 24);
  char buffer[8 + 10 + 1 + 32 + 1];  // "base-v" + digits + '+' + hex + NUL.
  int n = snprintf(buffer, sizeof(buffer), "base-v%u+",
                   static_cast<unsigned>(version));
  for (int i = 0; i < 16; i++) {
    n += snprintf(buffer + n, sizeof(buffer) - n, "%02x", record[8 + i]);
  }
  return process->allocate_string_or_error(buffer);
}

// Raw 32-bit register/memory access for bring-up diagnostics (the rig can
// inspect live peripheral state from a test container instead of needing a
// debugger). Aligned addresses only. Dev-platform tool — handle with care.
PRIMITIVE(peek32) {
  ARGS(int64, address);
  if (address < 0 || (address & 3) != 0) FAIL(INVALID_ARGUMENT);
  uint32_t value = *reinterpret_cast<volatile uint32_t*>((uintptr_t)address);
  return Primitive::integer((int64)value, process);
}

PRIMITIVE(poke32) {
  ARGS(int64, address, int64, value);
  if (address < 0 || (address & 3) != 0) FAIL(INVALID_ARGUMENT);
  *reinterpret_cast<volatile uint32_t*>((uintptr_t)address) =
      (uint32_t)(value & 0xffffffff);
  return process->null_object();
}

// EC618 watchdog — a software watchdog with a hardware busy-lockup backstop.
//
// Neither hardware watchdog on this chip can catch an *idle* application
// wedge (both HW-verified, 2026-06-09/10):
//
//  - The WDT module counts only CPU-ACTIVE time: its 32 kHz functional clock
//    (CLK_32K_GATED) is gated whenever the chip enters tickless idle / WFI,
//    and the clock mux has no always-on source. Verified with the vendor-
//    exact luat_wdt_setup sequence: armed at 10 s, feeds stopped, 72 s of
//    idle — no reset.
//
//  - The always-on (AON) watchdog belongs to the platform, not to us. The
//    boot ROM arms it (~27 s) and the CP core then auto-feeds it every couple
//    of seconds (its target register 0x4D020318 slides forward, target-now
//    pinned at ~20 s, with every AP-side feeder provably silent). It guards
//    whole-chip/CP liveness. It only ever fires when no healthy CP runs —
//    the early-bring-up ~27 s reboot loops (CONFIG_TOIT_EC618_VM_WATCHDOG=0
//    stops it at boot for CP-less debugging) — and it must be stopped before
//    hibernate, where the CP stops feeding (toit_ec618.cc does).
//
// So the real timeout is enforced in software: a dedicated FreeRTOS task
// (independent of the Toit scheduler thread, so it survives a wedged VM;
// FreeRTOS timed waits wake the chip from tickless idle, so it works through
// light sleep) checks a feed deadline and resets the chip when it passes.
// The task also kicks the WDT module: if the CPU is busy-locked hard enough
// to starve the task (IRQ-off spin, interrupt storm), the WDT accumulates
// active time with nobody kicking it and fires the hardware reset instead.
static volatile bool wd_armed = false;
static volatile uint32_t wd_timeout_ms = 0;
static volatile uint32_t wd_deadline = 0;     // In ticks (1 kHz, wraps; compared via int32 diff).
static bool wd_task_created = false;

// Cap on the task's sleep. Bounds the WDT-kick interval: legitimate heavy
// compute accrues at most this much active time between kicks, far below the
// backstop period, so the WDT only fires when the task is truly starved.
static const uint32_t WD_MAX_SLEEP_MS = 5000;
// The WDT backstop period in seconds of ACTIVE time (32 kHz / div(10) with a
// 32768 reload; interrupt+reset mode resets on the second expiry, so a
// starved-task busy lockup resets within 10-20 s of active time).
static const int WD_BACKSTOP_S = 10;

static void watchdog_task(void* arg) {
  (void)arg;
  while (true) {
    uint32_t sleep_ms = WD_MAX_SLEEP_MS;
    if (wd_armed) {
      WDT_kick();
      int32_t remain = (int32_t)(wd_deadline - osKernelGetTickCount());
      if (remain <= 0) {
        // Scope trigger (rail-drop diagnosis): PAD33 (board pin 31, the
        // ESP32-IO16 wire) goes HIGH before anything else in this path.
        // A rail drop WITHOUT this marker = the reset came from somewhere
        // else (e.g. the WDT busy-backstop or the platform's AON guard).
        pad_emergency_high(33);
        printf("[toit] FATAL: watchdog timeout (%u ms without feed) — resetting\n",
               (unsigned)wd_timeout_ms);
        ec618_system_reset();
      }
      if ((uint32_t)remain < sleep_ms) sleep_ms = (uint32_t)remain;
    }
    osDelay(sleep_ms);
  }
}

PRIMITIVE(watchdog_init) {
  ARGS(int, seconds);
  if (seconds < 1 || seconds > 60) FAIL(INVALID_ARGUMENT);
  wd_timeout_ms = (uint32_t)seconds * 1000;
  wd_deadline = osKernelGetTickCount() + wd_timeout_ms;
  if (!wd_task_created) {
    // Arm the busy-lockup backstop (see above) before the task that kicks it.
    GPR_setClockSrc(FCLK_WDG, FCLK_WDG_SEL_32K);
    GPR_setClockDiv(FCLK_WDG, WD_BACKSTOP_S);
    WdtConfig_t config;
    config.mode = WDT_INTERRUPT_RESET_MODE;
    config.timeoutValue = 32768U;
    WDT_init(&config);
    WDT_start();
    // Priority above the Toit task (20), so a spinning Toit process cannot
    // starve the watchdog check. Stack in words; 1024 = 4 KB covers printf.
    if (xTaskCreate(watchdog_task, "toit_wd", 1024, null, 30, null) != pdPASS) {
      WDT_stop();
      WDT_deInit();
      FAIL(MALLOC_FAILED);
    }
    wd_task_created = true;
  }
  wd_armed = true;
  return process->null_object();
}

PRIMITIVE(watchdog_feed) {
  if (wd_armed) wd_deadline = osKernelGetTickCount() + wd_timeout_ms;
  return process->null_object();
}

PRIMITIVE(watchdog_deinit) {
  wd_armed = false;
  // The task stays parked (one wake per 5 s); the backstop WDT keeps being
  // kicked by it, which is harmless and keeps the arm/disarm logic race-free.
  return process->null_object();
}

// Called from the deep-sleep path (toit_ec618.cc) after the VM has exited.
// An armed watchdog's deadline keeps counting while the chip waits to enter
// hibernate, and nobody feeds it any more — observed live as a FATAL reset
// 60 s after the last feed that masqueraded as a deep-sleep wake. Don't
// disarm it (a blocked sleep entry would then hang the device forever, and
// this rig has no remote reset); re-arm it as a generous backstop instead.
// A successful hibernate kills the task with the rest of the AP; a blocked
// entry self-recovers by reset after the sleep-path diagnostics have had
// time to print.
extern "C" void toit_watchdog_presleep() {
  if (!wd_armed) return;
  wd_timeout_ms = 120 * 1000;
  wd_deadline = osKernelGetTickCount() + wd_timeout_ms;
}

}  // namespace toit

#else  // !TOIT_EC618

#include "objects_inline.h"
#include "primitive.h"
#include "process.h"

namespace toit {

MODULE_IMPLEMENTATION(ec618, MODULE_EC618)

PRIMITIVE(print_uart_id) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(wakeup_pin_values) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_active) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_size) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_inactive_erase) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_inactive_write) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_reloc_begin) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_reloc_end) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_stage_and_reset) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_stage) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_mark_valid) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_mark_invalid_and_reset) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_trial) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_program_mode) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(modem_set_function) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(reset_reason) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(wakeup_cause) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(wakeup_pad_configure) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(wakeup_arm_flags) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(base_id) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(watchdog_init) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(watchdog_feed) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(watchdog_deinit) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(peek32) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(poke32) { FAIL(UNIMPLEMENTED); }

}  // namespace toit

#endif  // TOIT_EC618
