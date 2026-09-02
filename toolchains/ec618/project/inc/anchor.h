// Copyright (C) 2026 Toit contributors.
//
// Power-fail-safe active-slot marker for the dual-slot VM OTA. Record v3
// carries separate known-good and trial configurations alongside the boot
// state. A configuration is a partition table plus its console UART.
//
// The marker records which VM slot ('A'/'B') is the known-good one and,
// during an OTA, which slot is on trial and how far the trial has
// progressed. It is the EC618 analogue of esp-idf's `otadata` partition:
// two flash sectors hold a sequence-numbered, CRC-protected record; the
// reader picks the valid record with the higher sequence number, and the
// writer rewrites the *other* sector. One fully valid record therefore
// always survives a power loss or torn write mid-update. Because the
// configurations ride in the same record, boot state, flash layout and
// console flip as one atomic unit — a rollback restores all three.
//
// Both the PLAT boot dispatcher (toit_main.c) and the VM primitives
// (src/primitive_ec618.cc) use this module so the on-flash format and the
// power-fail rules live in exactly one place.

#ifndef TOIT_ANCHOR_H
#define TOIT_ANCHOR_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Distinguishes a written record from erased flash (0xffff) or all-zero.
#define ANCHOR_MAGIC ((uint16_t)0x4154)  // bytes 'T','A'
#define ANCHOR_VERSION ((uint8_t)3)

// The unprovisioned base carries these bytes at the exact start of the
// anchor region. gen-anchor verifies them before replacing both sectors,
// preventing a stale/mismatched descriptor from overwriting an arbitrary
// part of the AP image. This is a locator sentinel, not part of a written
// anchor record.
#define ANCHOR_SENTINEL_SIZE 16
#define ANCHOR_SENTINEL_BYTES               \
  {'T', 'O', 'I', 'T', '-', 'A', 'N',  'C', \
   'H', 'O', 'R', '-', 'V', '1', 0xa5, 0x5a}

// Cap on entries in either configuration. Two maximum-sized tables plus
// header/trailer fit comfortably in one 4 KiB record sector; the default
// table has 17 entries.
#define ANCHOR_MAX_ENTRIES 32

// Trial state of the `pending` slot. Only meaningful when pending != 0.
enum {
  SLOT_STATE_NONE = 0,            // No trial in progress.
  SLOT_STATE_NEW = 1,             // Staged, not yet booted once.
  SLOT_STATE_PENDING_VERIFY = 2,  // Booted once on trial, not yet confirmed.
};

// Partition types as stored in table entries. Mirrored by the host-side
// descriptor tooling (tools/ec618/partitions.toit).
enum {
  PARTITION_TYPE_LOCKED = 1,   // Vendor/boot territory; never Toit-managed.
  PARTITION_TYPE_BASE = 2,     // The frozen AP/PLAT base image.
  PARTITION_TYPE_BASE_ID = 3,  // The base version+fingerprint page.
  PARTITION_TYPE_ANCHOR = 4,   // This record's own two sectors.
  PARTITION_TYPE_SLOT = 5,     // A VM slot (first = 'A', second = 'B').
  PARTITION_TYPE_DATA = 6,     // Toit-managed data (flash registry, ...).
  PARTITION_TYPE_FREE = 7,     // Unassigned.
};

// One partition-table entry as stored in the record (32 bytes — a
// multiple of the 16-byte flash write segment for any entry count).
typedef struct {
  char name[16];    // NUL-padded.
  uint32_t offset;  // RAW flash address (add TOIT_PART_XIP_OFFSET for XIP).
  uint32_t size;
  uint8_t type;
  uint8_t reserved[7];
} partition_entry;

// The logical boot state of the current record. (The on-flash layout —
// header + table entries + CRC trailer — is private to anchor.c.)
typedef struct {
  uint8_t state;    // One of SLOT_STATE_*.
  uint32_t seq;     // Monotonic; the higher valid record wins.
  uint8_t active;   // 'A'/'B': last KNOWN-GOOD slot.
  uint8_t pending;  // 'A'/'B', or 0 = no trial in progress.
} slot_record;

// A configuration's console/control UART: 0/1/2 = that UART carries printf
// and the mini-jag control protocol; ANCHOR_CONSOLE_OFF = no redirect.
#define ANCHOR_CONSOLE_OFF ((uint8_t)0xff)

// Returns the console to initialize before the dispatcher runs: the trial
// console for a NEW record, otherwise the known-good console. Defaults to
// UART0 when no record exists so an unprovisioned halt loop stays visible.
uint8_t anchor_boot_console(void);

// Returns the console attached to `slot`: the trial console when `slot` is
// the pending slot, otherwise the known-good console.
uint8_t anchor_console_for_slot(uint8_t slot);

// Changes the console attached to the staged OTA. This is intentionally
// rejected unless a NEW trial exists: changing the running/known-good
// image's console outside an OTA transaction would make rollback ambiguous.
// Same program-mode requirement as the transition functions below.
bool anchor_set_pending_console(uint8_t console);

// Reads the current valid record (higher seq) into `out`. Returns true if
// a stored record was found; false if neither sector held a valid record
// (fresh flash) in which case `out` is filled with the defaults
// active='A', pending=0, state=NONE. `out` is always fully populated.
// Pure flash reads (XIP) — safe at early boot, needs no program mode.
bool anchor_read(slot_record* out);

// Copies the configuration attached to `slot` into out[0..max) and returns
// the entry count. When `slot` is the pending slot this is the trial table;
// otherwise it is the known-good table. Returns 0 when no valid record exists
// or the selected configuration has no table. Pure XIP reads.
int anchor_table_for_slot(uint8_t slot, partition_entry* out, int max);

// Stages `pending` as a NEW trial of `active`, cloning the known-good
// configuration for it. Rejected if another trial already exists. This is
// the currently exposed OTA path: layout changes are deliberately unavailable.
bool anchor_stage(uint8_t active, uint8_t pending);

// Same transaction, with an explicitly supplied trial configuration. Kept at
// the base layer and covered by host tests so a future migration implementation
// has power-fail-safe machinery to build on; it is not exposed to Toit yet.
bool anchor_stage_table(uint8_t active,
                        uint8_t pending,
                        const partition_entry* table,
                        int count,
                        uint8_t console);

// Persists NEW -> PENDING_VERIFY without changing either configuration.
bool anchor_consume_trial(uint8_t active, uint8_t pending);

// Promotes the pending slot and its configuration atomically, clearing the
// trial. Rejected unless `slot` is the pending slot.
bool anchor_validate(uint8_t slot);

// Discards the pending slot and its configuration atomically, retaining the
// known-good slot/configuration.
bool anchor_rollback(void);

// All transition functions fill magic/version/seq/crc internally, set seq to
// (current max valid seq) + 1, and rewrite only the sector that does NOT hold
// the current valid record. The live record therefore survives a torn write.
//
// REQUIRES the caller to have enabled firmware program/erase mode
// (fotaNvmNfsPeInit(1)) — the anchor lives in the protected AP-image
// region. The modify window consulted by sysROSpaceCheck is managed
// internally (saved and restored).
//
// Writes the initial known-good slot/configuration. `pending` must be zero,
// `state` must be NONE, and `count` must be <= ANCHOR_MAX_ENTRIES. This is the
// provisioning path used by the host-generated record and anchor tests.
bool anchor_write_table(uint8_t active,
                        uint8_t pending,
                        uint8_t state,
                        const partition_entry* table,
                        int count);

#ifdef __cplusplus
}
#endif

#endif  // TOIT_ANCHOR_H
