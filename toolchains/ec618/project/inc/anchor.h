// Copyright (C) 2026 Toit contributors.
//
// Power-fail-safe active-slot marker for the dual-slot VM OTA. Record v2
// carries the active partition table alongside the boot state.
//
// The marker records which VM slot ('A'/'B') is the known-good one and,
// during an OTA, which slot is on trial and how far the trial has
// progressed. It is the EC618 analogue of esp-idf's `otadata` partition:
// two flash sectors hold a sequence-numbered, CRC-protected record; the
// reader picks the valid record with the higher sequence number, and the
// writer rewrites the *other* sector. One fully valid record therefore
// always survives a power loss or torn write mid-update. Because the
// table rides in the same record, boot state and flash layout flip as one
// atomic unit — a rollback restores layout AND image.
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
#define ANCHOR_VERSION ((uint8_t)2)

// Cap on table entries the module stages in RAM (the on-flash format
// allows up to 127 in a sector; the default table has 17).
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
  char name[16];      // NUL-padded.
  uint32_t offset;    // RAW flash address (add TOIT_PART_XIP_OFFSET for XIP).
  uint32_t size;
  uint8_t type;
  uint8_t reserved[7];
} partition_entry;

// The logical boot state of the current record. (The on-flash layout —
// header + table entries + CRC trailer — is private to anchor.c.)
typedef struct {
  uint8_t state;      // One of SLOT_STATE_*.
  uint32_t seq;       // Monotonic; the higher valid record wins.
  uint8_t active;     // 'A'/'B': last KNOWN-GOOD slot.
  uint8_t pending;    // 'A'/'B', or 0 = no trial in progress.
} slot_record;

// The provisioned console/control UART: 0/1/2 = that UART carries printf
// and the mini-jag control protocol; ANCHOR_CONSOLE_OFF = no redirect.
// Per-device provisioning state (gen-anchor --console-uart), preserved by
// every write; the base reads it before its first print, the VM's
// print-uart-id primitive and the uart driver's shared-port check follow
// it. Defaults to UART0 when no record exists so an unprovisioned
// device's halt loop stays visible.
#define ANCHOR_CONSOLE_OFF ((uint8_t)0xff)
uint8_t anchor_console(void);

// Rewrites the record with a new console byte, preserving boot state and
// table. Same program-mode requirement as anchor_write.
bool anchor_set_console(uint8_t console);

// Reads the current valid record (higher seq) into `out`. Returns true if
// a stored record was found; false if neither sector held a valid record
// (fresh flash) in which case `out` is filled with the defaults
// active='A', pending=0, state=NONE. `out` is always fully populated.
// Pure flash reads (XIP) — safe at early boot, needs no program mode.
bool anchor_read(slot_record* out);

// Copies the ACTIVE partition table into out[0..max) and returns the
// entry count. Returns 0 when no valid record exists or the record
// carries no table — there is NO compiled-in fallback: the table is
// written at provisioning time and a device without one cannot boot
// (the dispatcher halts loudly). Pure XIP reads.
int anchor_table(partition_entry* out, int max);

// Commits a new {active, pending, state}, PRESERVING the stored table
// (a record without a table stays without one — plain boot-state flips
// never bake a layout in). magic/version/seq/crc are filled internally;
// seq is set to (current max valid seq) + 1. Erases and writes only the
// sector that does NOT hold the current valid record, so the live record
// is never destroyed. Returns true on success.
//
// REQUIRES the caller to have enabled firmware program/erase mode
// (fotaNvmNfsPeInit(1)) — the anchor lives in the protected AP-image
// region. The modify window consulted by sysROSpaceCheck is managed
// internally (saved and restored).
bool anchor_write(uint8_t active, uint8_t pending, uint8_t state);

// Commits boot state AND table as one atomic record (the provisioning /
// layout-change path). `count` must be <= ANCHOR_MAX_ENTRIES;
// `table` may be NULL with count 0 to strip the table. Same program-mode
// requirement as anchor_write.
bool anchor_write_table(uint8_t active, uint8_t pending, uint8_t state,
                             const partition_entry* table, int count);

#ifdef __cplusplus
}
#endif

#endif  // TOIT_ANCHOR_H
