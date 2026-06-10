// Copyright (C) 2026 Toit contributors.
//
// Power-fail-safe active-slot marker for the dual-slot VM OTA.
//
// The marker records which VM slot ('A'/'B') is the known-good one and,
// during an OTA, which slot is on trial and how far the trial has
// progressed. It is the EC618 analogue of esp-idf's `otadata` partition:
// two flash sectors hold a sequence-numbered, CRC-protected record; the
// reader picks the valid record with the higher sequence number, and the
// writer rewrites the *other* sector. One fully valid record therefore
// always survives a power loss or torn write mid-update.
//
// Both the PLAT boot dispatcher (toit_main.c) and the VM primitives
// (src/primitive_ec618.cc) use this module so the on-flash format and the
// power-fail rules live in exactly one place.

#ifndef TOIT_SLOT_MARKER_H
#define TOIT_SLOT_MARKER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Distinguishes a written record from erased flash (0xffff) or all-zero.
#define SLOT_MARKER_MAGIC ((uint16_t)0x5453)  // bytes 'S','T'
#define SLOT_MARKER_VERSION ((uint8_t)1)

// Trial state of the `pending` slot. Only meaningful when pending != 0.
enum {
  SLOT_STATE_NONE = 0,            // No trial in progress.
  SLOT_STATE_NEW = 1,            // Staged, not yet booted once.
  SLOT_STATE_PENDING_VERIFY = 2,  // Booted once on trial, not yet confirmed.
};

// One marker record. Exactly one 16-byte flash segment so it is written
// in a single BSP_QSPI_Write_Safe call. crc32 covers the first 12 bytes.
typedef struct {
  uint16_t magic;     // SLOT_MARKER_MAGIC.
  uint8_t version;    // SLOT_MARKER_VERSION.
  uint8_t state;      // One of SLOT_STATE_*.
  uint32_t seq;       // Monotonic; the higher valid record wins.
  uint8_t active;     // 'A'/'B': last KNOWN-GOOD slot.
  uint8_t pending;    // 'A'/'B', or 0 = no trial in progress.
  uint8_t reserved[2];
  uint32_t crc32;     // Over bytes [0..11], written last.
} slot_record;

// Reads the current valid record (higher seq) into `out`. Returns true if
// a stored record was found; false if neither sector held a valid record
// (fresh flash) in which case `out` is filled with the defaults
// active='A', pending=0, state=NONE. `out` is always fully populated.
// Pure flash reads (XIP) — safe at early boot, needs no program mode.
bool slot_marker_read(slot_record* out);

// Commits a new {active, pending, state}. magic/version/seq/crc are filled
// internally; seq is set to (current max valid seq) + 1. Erases and writes
// only the sector that does NOT hold the current valid record, so the live
// record is never destroyed. Returns true on success.
//
// REQUIRES the caller to have enabled firmware program/erase mode
// (fotaNvmNfsPeInit(1)) — the marker lives in the protected AP-image
// region. The modify window consulted by sysROSpaceCheck is managed
// internally (saved and restored).
bool slot_marker_write(uint8_t active, uint8_t pending, uint8_t state);

#ifdef __cplusplus
}
#endif

#endif  // TOIT_SLOT_MARKER_H
