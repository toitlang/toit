// Copyright (C) 2026 Toit contributors.
//
// Entry point and slot dispatcher for the Toit runtime on EC618.
//
// This is the EC618 analogue of esp-idf's bootloader rollback logic. It
// reads the power-fail-safe active-slot record (.toit_anchor, two sectors,
// see anchor.c), decides which VM slot to boot, and implements the
// trial/rollback state machine:
//
//   - No trial pending  -> boot the known-good `active` slot.
//   - Trial pending, NEW -> "consume" the trial by persisting
//     PENDING_VERIFY *before* running the (maybe-broken) VM, then boot the
//     pending slot. The running VM must call slot_mark_valid to confirm.
//   - Trial pending, PENDING_VERIFY -> the previous trial boot never
//     confirmed itself -> roll back to `active`.
//
// Because the consume step is persisted before the VM runs, a crash loop
// cannot retry a bad slot forever — the next boot sees PENDING_VERIFY and
// rolls back. Flash writes happen here only while a trial is in progress;
// steady-state boots are pure reads.
//
// Each VM slot's first word is a function pointer to its own toit_start
// (.vm_entry); the dispatcher tail-calls through it, which is what makes
// dual-linked A/B slots work without a fixed-offset entry symbol.

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "common_api.h"
// TODO(toit): drop the LuatOS `luat_*` interface layer from the EC618 glue.
// The Toit VM resources (gpio/i2c/uart/adc/...) bind the PLAT driver/HAL
// directly; the glue should too, so we don't depend on the LuatOS interface
// layer at all. Remaining users: this file (luat_rtos_task_*) and plat_jt.c's
// jump-table entries (luat_rtos_task_*, luat_uart_*, luat_mobile_config).
// Replace luat_rtos_task_* with the FreeRTOS task API directly.
#include "luat_rtos.h"
#include "mem_map.h"    // AP_FLASH_XIP_ADDR.
#include "anchor.h"

// From the SDK FOTA layer: opens the protected AP-image region for
// program/erase. Required around any anchor write (the anchor lives in
// that region). Non-nested enable -> write -> disable, like the SDK FOTA.
extern void fotaNvmNfsPeInit(unsigned char isSmall);

// Pins the .toit_anchor output section so it is emitted as real bytes
// (the linker reserves both sectors after it). Fresh/erased contents read
// as "no valid record": provisioning writes the real record; without one
// the device refuses to boot (load_boot_table).
__attribute__((section(".toit_anchor"), used))
const uint8_t toit_anchor_section_byte = 0xff;

// The slot the dispatcher actually booted ('A'/'B'). RAM global, set once
// below before the VM runs. The VM primitives read this as "the slot I am
// running from" — after a NEW->PENDING_VERIFY consume it is the pending
// slot, not the record's `active`, so the raw record is not authoritative.
uint8_t toit_booted_slot = 'A';

typedef void (*toit_start_fn)(void);

static luat_rtos_task_handle toit_task_handle;

// The ACTIVE partition table, read from the anchor record once at boot.
// The dispatcher boots from ITS slot entries — this is what makes the
// layout follow the record instead of the link: the first `slot` entry
// is 'A', the second is 'B'. There is NO compiled-in fallback: the record
// is written at provisioning time, and a device without a valid one
// cannot boot (see load_boot_table).
static partition_entry boot_table[ANCHOR_MAX_ENTRIES];
static int boot_table_count;

// Returns the table entry of slot `slot` ('A'/'B'), or NULL if the table
// does not carry two slot entries.
static const partition_entry* slot_entry(uint8_t slot) {
  int seen = 0;
  for (int i = 0; i < boot_table_count; i++) {
    if (boot_table[i].type != PARTITION_TYPE_SLOT) continue;
    if (seen == (slot == 'B' ? 1 : 0)) return &boot_table[i];
    seen++;
  }
  return NULL;
}

// Returns the XIP base of slot `slot` ('A'/'B') per the active table.
static const uint32_t* slot_base(uint8_t slot) {
  return (const uint32_t*)(uintptr_t)(slot_entry(slot)->offset + AP_FLASH_XIP_ADDR);
}

// Sanity-checks that slot `slot` holds a plausible image: its first word
// (.vm_entry) must be a Thumb pointer (odd) inside the slot's own range.
// Cheap defense against booting a never-written / half-erased slot; the
// strong SHA check is a stage-time gate, too slow to repeat every boot.
static bool slot_entry_ok(uint8_t slot) {
  const uint32_t* base = slot_base(slot);
  uint32_t entry = base[0];
  uint32_t lo = (uint32_t)(uintptr_t)base;
  return (entry & 1u) && entry >= lo && entry < lo + slot_entry(slot)->size;
}

// Loads the active table. A device whose anchor record is missing,
// corrupt, or has no two bootable slots CANNOT boot — halt loudly
// (periodic print so a console shows why) instead of jumping into
// garbage. Reaching this state means provisioning never ran or the
// anchor sectors were destroyed; the ping-ponged record makes power
// loss unable to cause it.
static void load_boot_table(void) {
  boot_table_count = anchor_table(boot_table, ANCHOR_MAX_ENTRIES);
  while (boot_table_count == 0 || slot_entry('A') == NULL || slot_entry('B') == NULL) {
    printf("[toit] ERROR: no valid partition table at the anchor — cannot boot. "
           "Reflash the device (provisioning writes the table).\n");
    luat_rtos_task_sleep(5000);
  }
}

// Persists an anchor transition, bracketed by program/erase mode (the
// marker is in the protected AP image). Returns anchor_write's result.
static bool dispatcher_commit(uint8_t active, uint8_t pending, uint8_t state) {
  fotaNvmNfsPeInit(1);
  bool ok = anchor_write(active, pending, state);
  fotaNvmNfsPeInit(0);
  return ok;
}

// Runs the trial/rollback state machine and returns the slot to boot.
static uint8_t choose_boot_slot(void) {
  slot_record rec;
  anchor_read(&rec);

  if (rec.pending != 0) {
    if (rec.state == SLOT_STATE_NEW) {
      // Consume the trial before running the VM. If we cannot persist that
      // fact, fail safe to the known-good slot rather than risk an
      // un-rollback-able crash loop on the pending slot.
      if (dispatcher_commit(rec.active, rec.pending, SLOT_STATE_PENDING_VERIFY)) {
        printf("[toit] INFO: trial boot of slot %c (was %c)\n", rec.pending, rec.active);
        return rec.pending;
      }
      printf("[toit] ERROR: could not arm trial of slot %c; booting %c\n",
             rec.pending, rec.active);
      return rec.active;
    }
    // PENDING_VERIFY: a prior trial boot never confirmed itself -> abort it.
    // Booting `active` is correct even if the clear-write fails (the next
    // boot just retries the same rollback).
    dispatcher_commit(rec.active, 0, SLOT_STATE_NONE);
    printf("[toit] INFO: rollback to slot %c (trial of %c not confirmed)\n",
           rec.active, rec.pending);
    return rec.active;
  }

  return rec.active;
}

static void toit_task(void *param) {
  load_boot_table();
  uint8_t slot = choose_boot_slot();

  // Refuse to jump into a slot whose entry pointer looks broken; prefer the
  // other slot if it looks good.
  if (!slot_entry_ok(slot)) {
    uint8_t other = (slot == 'B') ? 'A' : 'B';
    printf("[toit] WARN: slot %c entry invalid\n", slot);
    if (slot_entry_ok(other)) slot = other;
  }

  toit_booted_slot = slot;
  printf("[toit] INFO: booting VM slot %c\n", slot);

  // The slot's first word is a function pointer (.vm_entry, written by the
  // VM build). The Thumb bit is already set, so a plain indirect call lands
  // in toit_start.
  toit_start_fn entry = (toit_start_fn)slot_base(slot)[0];
  entry();

  // toit_start() does not return in normal operation (enters deep sleep).
  // If it does return, halt.
  while (1) {
    luat_rtos_task_sleep(10000);
  }
}

static void toit_task_init(void) {
  // 8KB stack for the Toit main task.
  luat_rtos_task_create(&toit_task_handle, 8 * 1024, 20, "toit", toit_task, NULL, 0);
}

// Register at task init level 1 (runs after hardware and driver init).
INIT_TASK_EXPORT(toit_task_init, "1");
