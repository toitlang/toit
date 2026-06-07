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
  #include "reset.h"  // ResetStateGet / LastResetState_e.
  #include "wdt.h"    // The hardware watchdog (WDT) driver.
  #include "clock.h"  // GPR_setClock* for the WDT functional clock.
  #include "slpman.h"  // slpManAonWdtFeed.

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
static const uint32_t SLOT_SIZE = 0xC0000;  // 768 KB; mirrors TOIT_VM_SLOT_SIZE.

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
  const uint32_t body_sectors_end =
      (slot_reloc_table.body_size + FLASH_SECTOR_SIZE - 1) & ~(FLASH_SECTOR_SIZE - 1);
  if (body_sectors_end > trailer_first_sector) {
    free(copy);
    FAIL(OUT_OF_BOUNDS);  // Body and trailer would share a sector.
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

// EC618 hardware watchdog (WDT module). The PLAT ships a higher-level
// luat_wdt_* wrapper, but it isn't linked into this firmware, so we drive
// the WDT driver directly (this mirrors luat_wdt_setup). The watchdog runs
// off the 32 kHz clock: with the functional-clock divider set to the
// timeout in seconds and the counter reload fixed at 32768, one counter
// period equals `seconds` seconds. In WDT_INTERRUPT_RESET_MODE the first
// expiry only raises an (unhandled) interrupt; the chip resets on the
// second expiry, so an unfed watchdog resets the device after up to twice
// the timeout. Feeding (WDT_kick) clears the counter.
PRIMITIVE(watchdog_init) {
  ARGS(int, seconds);
  if (seconds < 1 || seconds > 60) FAIL(INVALID_ARGUMENT);
  GPR_setClockSrc(FCLK_WDG, FCLK_WDG_SEL_32K);
  GPR_setClockDiv(FCLK_WDG, seconds);
  WdtConfig_t config;
  config.mode = WDT_INTERRUPT_RESET_MODE;
  config.timeoutValue = 32768U;
  WDT_init(&config);
  WDT_start();
  return process->null_object();
}

PRIMITIVE(watchdog_feed) {
  WDT_kick();
  slpManAonWdtFeed();  // No-op while the AON watchdog is stopped, but kept
                       // in sync with the PLAT's own feed sequence.
  return process->null_object();
}

PRIMITIVE(watchdog_deinit) {
  WDT_stop();
  WDT_deInit();
  return process->null_object();
}

}  // namespace toit

#else  // !TOIT_EC618

#include "objects_inline.h"
#include "primitive.h"
#include "process.h"

namespace toit {

MODULE_IMPLEMENTATION(ec618, MODULE_EC618)

PRIMITIVE(print_uart_id) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(slot_active) { FAIL(UNIMPLEMENTED); }
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
PRIMITIVE(watchdog_init) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(watchdog_feed) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(watchdog_deinit) { FAIL(UNIMPLEMENTED); }

}  // namespace toit

#endif  // TOIT_EC618
