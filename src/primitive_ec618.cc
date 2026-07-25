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
#include "watchdog_ec618.h"

extern "C" {
  #include "flash_rt.h"
  #include "mem_map.h"
  #include "anchor.h"
  #include "reset.h"  // ResetStateGet / LastResetState_e.

  // From slpman in the selected frozen base: live AON wakeup-pad levels, and
  // the latched wakeup source of the most recent boot (slpManWakeSrc_e).
  uint32_t slpManGetWakeupPinValue(void);
  int slpManGetWakeupSrc(void);

  // From the SDK FOTA layer (luat_flash_ctrl_fw_sectors -> this). Must be
  // set (1) around any erase/write into the protected AP-image region;
  // it is the mode the SDK FOTA uses to write firmware there while the
  // system runs (the slot_program_mode primitive).
  void fotaNvmNfsPeInit(unsigned char isSmall);

  // Writable window for flash operations against the AP image, consulted
  // by sysROSpaceCheck (overridden in sys_ro_override.c).
  extern uint32_t toit_ap_image_modify_start;
  extern uint32_t toit_ap_image_modify_end;

  // Base linker-script symbol: the base-id record page (frozen contract,
  // resolved per base via --just-symbols). Declared as an array so
  // referring to it gives its address.
  extern uint8_t __toit_base_id_start[];

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
// base-id page directly after the base image.
static uintptr_t base_id_xip() {
  return reinterpret_cast<uintptr_t>(__toit_base_id_start);
}

struct BaseId {
  uint32_t version;
  const uint8_t* fingerprint;
};

static bool read_base_id(BaseId* id) {
  const uint8_t* record = reinterpret_cast<const uint8_t*>(base_id_xip());
  if (!(record[0] == 'T' && record[1] == 'B' &&
        record[2] == 'I' && record[3] == '1')) {
    return false;
  }
  id->version = static_cast<uint32_t>(record[4]) |
                (static_cast<uint32_t>(record[5]) << 8) |
                (static_cast<uint32_t>(record[6]) << 16) |
                (static_cast<uint32_t>(record[7]) << 24);
  id->fingerprint = record + 8;
  return true;
}

MODULE_IMPLEMENTATION(ec618, MODULE_EC618)

PRIMITIVE(console_uart_id) {
  // Returns the UART id (0/1/2) the firmware redirects `print` to, or -1
  // if the redirect was disabled at build time. This lets test programs
  // adapt to whichever firmware variant is loaded without rebuilding.
#if CONFIG_TOIT_EC618_PRINT_UART
  int console = anchor_console();
  return Smi::from(console > 2 ? -1 : console);
#else
  return Smi::from(-1);
#endif
}

// Sets the provisioned console/control UART in the anchor record (0/1/2,
// or 0xff to disable the redirect). Takes effect on the NEXT boot — the
// base reads the byte before its first print. Preserves boot state and
// table; brackets the flash write in program mode like the dispatcher.
PRIMITIVE(console_uart_set) {
  ARGS(int, console);
  if (console != 0xff && (console < 0 || console > 2)) FAIL(INVALID_ARGUMENT);
  fotaNvmNfsPeInit(1);
  bool ok = anchor_set_console((uint8_t)console);
  fotaNvmNfsPeInit(0);
  if (!ok) FAIL(ERROR);
  return process->null_object();
}

// Dual-slot OTA primitives. The current build dispatches between
// .vm_a (slot A) and .vm_b (slot B) based on .toit_anchor; these
// primitives let a Toit container receive a new VM image, write it
// into whichever slot isn't currently active, and atomically switch.

// The ACTIVE partition table, read from the anchor record on first use.
// The dispatcher refuses to boot without a valid table, so the zero-count
// case cannot happen in practice; it just makes every geometry lookup
// (and with it every bounds check) fail closed.
static partition_entry vm_table[ANCHOR_MAX_ENTRIES];
static int vm_table_count = -1;

// Returns the table entry of slot `slot` ('A'/'B' = first/second `slot`
// entry), or null. Idempotent-fill: a racing first call writes identical
// data, and the count is published after the entries.
static const partition_entry* slot_entry(uint8_t slot) {
  if (vm_table_count < 0) {
    int count = anchor_table(vm_table, ANCHOR_MAX_ENTRIES);
    vm_table_count = count;  // Published after the entries.
  }
  int seen = 0;
  for (int i = 0; i < vm_table_count; i++) {
    if (vm_table[i].type != PARTITION_TYPE_SLOT) continue;
    if (seen == (slot == 'B' ? 1 : 0)) return &vm_table[i];
    seen++;
  }
  return null;
}

// XIP base address of slot `slot` per the active table.
static uint32_t slot_base_xip(uint8_t slot) {
  const partition_entry* entry = slot_entry(slot);
  return entry ? (entry->offset + AP_FLASH_XIP_ADDR) : 0;
}

// Size of one VM slot per the active table (both slots share one size).
// Every erase/write below is bounds-checked against it so a buggy Toit
// caller can't run off the end of a slot into neighboring regions.
static uint32_t slot_size() {
  const partition_entry* entry = slot_entry('A');
  return entry ? entry->size : 0;
}

// Returns the VM slot the runtime is currently executing from — 'A' or 'B'
// as ASCII bytes. This is the slot the dispatcher booted, which during a
// trial is the pending slot (not the record's known-good `active`).
PRIMITIVE(slot_active) {
  return Smi::from(toit_booted_slot);
}

// Returns the slot size of the ACTIVE layout (the anchor record's table),
// so the Toit side never carries its own copy of the geometry.
PRIMITIVE(slot_size) {
  return Smi::from(slot_size());
}

// The slot that is NOT the one we are running from (the OTA target).
static uint8_t inactive_slot() {
  return (toit_booted_slot == 'B') ? 'A' : 'B';
}

// Returns the XIP base address of the inactive slot — where
// slot_inactive_write deposits new bytes.
static uint32_t inactive_slot_base() {
  return slot_base_xip(inactive_slot());
}

// Returns the XIP base address of the slot the runtime booted from.
static uint32_t active_slot_base() {
  return slot_base_xip(toit_booted_slot);
}

// Active-slot canonical firmware view (convergence #3 read path). firmware.map
// presents the running slot as its CANONICAL image (table-first, un-relocated)
// through SlotFirmware, so the integrity SHA and delta-OTA see the same bytes
// regardless of which slot is live. The helpers below back the firmware_map /
// firmware_mapping_at / firmware_mapping_copy core primitives
// (src/primitive_core.cc) on the EC618 target.
//
// This deliberately is not a mapping resource like ESP32's temporary mmap:
// EC618 XIP stays mapped, the active slot is immutable until reset, and the
// view only borrows those bytes. It owns no allocation or handle to clean up.
// Multiple FirmwareMapping instances keep their own ranges and read the same
// immutable canonical view.
static SlotFirmware g_active_firmware;

// Opens the view over the running slot and returns its canonical size (0 on
// failure). `*base_out` receives the slot's XIP base, used only so the firmware
// proxy carries a valid (if unread) external address.
uint32_t ec618_active_firmware_open(uint8_t** base_out) {
  uint32_t base = active_slot_base();
  *base_out = reinterpret_cast<uint8_t*>(base);
  if (!g_active_firmware.open(reinterpret_cast<const uint8_t*>(base), base, slot_size())) {
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

// Relocate-on-write context. The native state is process-global because flash
// program mode and the inactive slot are device-global. Its owner is the
// system firmware provider's single ServiceResource: the primitives below are
// PRIVILEGED, the provider rejects a second writer, and resource teardown on
// explicit close or client death calls slot_reloc_end and leaves program mode.
//
// The OTA receiver streams the CANONICAL
// (link-base) image; slot_reloc_begin arms relocation with that image's reloc
// table (the "SRL3" artifact, see src/slot_reloc_ec618.h), and
// slot_inactive_write relocates each chunk onto the destination slot before
// the flash write — so the relocation is invisible to the (architecture-
// agnostic) Toit firmware code. `slot_reloc_delta = dest_slot_base - link_base`
// is 0 when the canonical image lands at its link home and the slot
// displacement otherwise.
static uint8_t* slot_reloc_blob = null;  // Owned copy of the SRL3 table bytes.
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

  // Base-id gate: the incoming image's SRL3 table
  // carries the base it was linked against; refuse it if that is not the
  // base THIS device runs — a mismatched slot would branch to addresses the
  // flashed base does not have, an undebuggable fault. The device's own
  // record is stamped by gen-base-id.toit into the reserved flash page.
  {
    BaseId device;
    bool device_ok = read_base_id(&device);
    bool match = device_ok && device.version == slot_reloc_table.base_version &&
                 memcmp(device.fingerprint, slot_reloc_table.base_fp, 16) == 0;
    if (!match) {
      printf("[toit] ERROR: base mismatch — image built for base-v%u, "
             "device runs base-v%u%s; full-flash the matching base\n",
             static_cast<unsigned>(slot_reloc_table.base_version),
             static_cast<unsigned>(device_ok ? device.version : 0),
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
  const uint32_t block_size =
      Utils::round_up(static_cast<uint32_t>(length) + 4, FLASH_SEGMENT_SIZE);
  if (block_size > slot_size()) { free(copy); FAIL(OUT_OF_BOUNDS); }
  const uint32_t trailer_first_sector =
      Utils::round_down(slot_size() - block_size, FLASH_SECTOR_SIZE);
  // The populated front is body + extension (body_size) PLUS the verbatim VM
  // .data init image that rides after it (data_size) — both are streamed
  // front-to-back with a lazy per-sector erase, so the whole front must clear
  // the trailer's sectors.
  const uint32_t front = slot_reloc_table.body_size + slot_reloc_table.data_size;
  const uint32_t front_sectors_end = Utils::round_up(front, FLASH_SECTOR_SIZE);
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
  toit_ap_image_modify_end = base_phys + slot_size();
  // Erase the trailer's sectors, then write the block into them.
  int rc = QSPI_OK;
  for (uint32_t s = trailer_first_sector; s < slot_size(); s += FLASH_SECTOR_SIZE) {
    rc = BSP_QSPI_Erase_Safe(base_phys + s, FLASH_SECTOR_SIZE);
    if (rc != QSPI_OK) break;
  }
  if (rc == QSPI_OK) {
    rc = BSP_QSPI_Write_Safe(block, base_phys + slot_size() - block_size, block_size);
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
  if (static_cast<uint32_t>(offset) >= slot_size()) FAIL(OUT_OF_BOUNDS);

  const uint32_t base_xip = inactive_slot_base();
  const uint32_t base_phys = base_xip - AP_FLASH_XIP_ADDR;
  const uint32_t dest = base_phys + static_cast<uint32_t>(offset);

  uint32_t saved_start = toit_ap_image_modify_start;
  uint32_t saved_end = toit_ap_image_modify_end;
  toit_ap_image_modify_start = base_phys;
  toit_ap_image_modify_end = base_phys + slot_size();

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
// slot_size(). Length must be a multiple of FLASH_SEGMENT_SIZE (16 B) —
// BSP_QSPI_Write_Safe requires segment-aligned writes.
PRIMITIVE(slot_inactive_write) {
  PRIVILEGED;
  ARGS(int, offset, Blob, bytes);

  if (offset < 0) FAIL(INVALID_ARGUMENT);
  const uint32_t length = static_cast<uint32_t>(bytes.length());
  if (length % FLASH_SEGMENT_SIZE != 0) FAIL(INVALID_ARGUMENT);
  if (length > FLASH_SECTOR_SIZE) FAIL(OUT_OF_BOUNDS);
  const uint32_t off = static_cast<uint32_t>(offset);
  if (off % FLASH_SEGMENT_SIZE != 0) FAIL(INVALID_ARGUMENT);
  if (off > slot_size() || length > slot_size() - off) FAIL(OUT_OF_BOUNDS);

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
    relocated = unvoid_cast<uint8_t*>(malloc(length));
    if (relocated == null) FAIL(MALLOC_FAILED);
    memcpy(relocated, bytes.address(), length);
    if (!slot_reloc_apply(&slot_reloc_table, relocated, off, length,
                          slot_reloc_delta, SLOT_RELOC_TO_SLOT)) {
      free(relocated);
      FAIL(INVALID_ARGUMENT);
    }
    source = relocated;
  }

  uint32_t saved_start = toit_ap_image_modify_start;
  uint32_t saved_end = toit_ap_image_modify_end;
  toit_ap_image_modify_start = base_phys;
  toit_ap_image_modify_end = base_phys + slot_size();

  // BSP_QSPI_Write_Safe disables XIP for the duration of the call. The
  // source must live in RAM — both Blob::address() (a process-heap pointer)
  // and the relocation scratch are in MSMB RAM.
  int rc = BSP_QSPI_Write_Safe(
      const_cast<uint8_t*>(source), dest, length);

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
  ResetECSystemReset();
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
  if (!anchor_write(toit_booted_slot, inactive_slot(), SLOT_STATE_NEW)) {
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
  if (!anchor_write(toit_booted_slot, inactive_slot(), SLOT_STATE_NEW)) {
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
  bool ok = anchor_write(toit_booted_slot, 0, SLOT_STATE_NONE);
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
  anchor_read(&rec);
  // If we are the pending trial, fall back to the record's active; otherwise
  // (already the active slot) there is nothing to roll back to but the
  // other slot, so target it.
  uint8_t fallback = (rec.pending == toit_booted_slot) ? rec.active : inactive_slot();

  fotaNvmNfsPeInit(1);
  bool ok = anchor_write(fallback, 0, SLOT_STATE_NONE);
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
  anchor_read(&rec);
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
// statics live in .bss, so this state is OTA-slot-safe. The deep-sleep chain
// stores and restores them across intermediate timer wakes.
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

extern "C" void toit_restore_wakeup_config(
    const uint8_t* configs,
    int flags) {
  memcpy(wakeup_pad_configs_, configs, sizeof(wakeup_pad_configs_));
  wakeup_arm_flags_ = flags;
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
  BaseId id;
  if (!read_base_id(&id)) {
    return process->allocate_string_or_error("base-unknown");
  }
  char buffer[8 + 10 + 1 + 32 + 1];  // "base-v" + digits + '+' + hex + NUL.
  int n = snprintf(buffer, sizeof(buffer), "base-v%u+",
                   static_cast<unsigned>(id.version));
  for (int i = 0; i < 16; i++) {
    n += snprintf(buffer + n, sizeof(buffer) - n, "%02x", id.fingerprint[i]);
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

PRIMITIVE(watchdog_init) {
  ARGS(int, seconds);
  if (seconds < 1 || seconds > 60) FAIL(INVALID_ARGUMENT);
  if (!ec618_watchdog_init(seconds)) FAIL(MALLOC_FAILED);
  return process->null_object();
}

PRIMITIVE(watchdog_feed) {
  ec618_watchdog_feed();
  return process->null_object();
}

PRIMITIVE(watchdog_deinit) {
  ec618_watchdog_deinit();
  return process->null_object();
}

}  // namespace toit

#else  // !TOIT_EC618

#include "objects_inline.h"
#include "primitive.h"
#include "process.h"

namespace toit {

MODULE_IMPLEMENTATION(ec618, MODULE_EC618)

#define EC618_UNIMPLEMENTED(name, arity) \
  PRIMITIVE(name) { FAIL(UNIMPLEMENTED); }
MODULE_EC618(EC618_UNIMPLEMENTED)
#undef EC618_UNIMPLEMENTED

}  // namespace toit

#endif  // TOIT_EC618
