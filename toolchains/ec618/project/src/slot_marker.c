// Copyright (C) 2026 Toit contributors.
//
// See slot_marker.h for the design. Two flash sectors hold a
// sequence-numbered, CRC-protected record; reads pick the valid record
// with the higher sequence number, writes rewrite the *other* sector.

#include "slot_marker.h"

#include <string.h>

#include "flash_rt.h"   // BSP_QSPI_Erase_Safe / BSP_QSPI_Write_Safe / QSPI_OK
#include "mem_map.h"    // AP_FLASH_XIP_ADDR

// Defined in sys_ro_override.c: the writable window sysROSpaceCheck allows
// against the protected AP image. Saved and restored around our erase/write.
extern uint32_t toit_ap_image_modify_start;
extern uint32_t toit_ap_image_modify_end;

// Linker-script symbol: XIP base of the two-sector .slot_marker region.
// Declared as an array so referring to it yields its address.
extern uint8_t __slot_marker_start[];

#define MARKER_SECTOR_SIZE 0x1000u
#define MARKER_RECORD_SIZE 16u

_Static_assert(sizeof(slot_record) == MARKER_RECORD_SIZE,
               "slot_record must be exactly one 16-byte flash segment");

// Standard CRC-32 (poly 0xEDB88320), computed bitwise — the input is only
// 12 bytes so a table is not worth the .rodata.
static uint32_t marker_crc32(const uint8_t* data, uint32_t len) {
  uint32_t crc = 0xffffffffu;
  for (uint32_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (int b = 0; b < 8; b++) {
      uint32_t mask = -(crc & 1u);
      crc = (crc >> 1) ^ (0xedb88320u & mask);
    }
  }
  return ~crc;
}

// XIP address of sector `idx` (0 or 1) of the marker region.
static const uint8_t* marker_sector_xip(int idx) {
  return (const uint8_t*)((uintptr_t)__slot_marker_start + (uintptr_t)idx * MARKER_SECTOR_SIZE);
}

// Reads sector `idx` via XIP and validates magic + crc. Returns true and
// fills `out` if the sector holds a well-formed record.
static bool marker_read_sector(int idx, slot_record* out) {
  memcpy(out, marker_sector_xip(idx), sizeof(*out));
  if (out->magic != SLOT_MARKER_MAGIC) return false;
  // crc covers everything before the trailing crc32 field (12 bytes).
  if (marker_crc32((const uint8_t*)out, MARKER_RECORD_SIZE - 4) != out->crc32) {
    return false;
  }
  return true;
}

bool slot_marker_read(slot_record* out) {
  slot_record r0, r1;
  bool v0 = marker_read_sector(0, &r0);
  bool v1 = marker_read_sector(1, &r1);

  if (v0 && (!v1 || r0.seq >= r1.seq)) {
    *out = r0;
    return true;
  }
  if (v1) {
    *out = r1;
    return true;
  }

  // Fresh flash (both sectors erased/garbage): default to slot A, no trial.
  // Matches the pre-rollback behaviour where an erased marker meant slot A.
  memset(out, 0, sizeof(*out));
  out->magic = SLOT_MARKER_MAGIC;
  out->version = SLOT_MARKER_VERSION;
  out->state = SLOT_STATE_NONE;
  out->seq = 0;
  out->active = 'A';
  out->pending = 0;
  return false;
}

bool slot_marker_write(uint8_t active, uint8_t pending, uint8_t state) {
  slot_record r0, r1;
  bool v0 = marker_read_sector(0, &r0);
  bool v1 = marker_read_sector(1, &r1);

  uint32_t max_seq = 0;
  int current = -1;  // Sector holding the current valid (higher-seq) record.
  if (v0) {
    max_seq = r0.seq;
    current = 0;
  }
  if (v1 && (!v0 || r1.seq > r0.seq)) {
    max_seq = r1.seq;
    current = 1;
  }
  // Write to the sector that is NOT current valid, so the live record
  // survives a torn erase/write. (current == -1 ⇒ neither valid ⇒ sector 0.)
  int target = (current == 0) ? 1 : 0;

  slot_record rec;
  memset(&rec, 0, sizeof(rec));
  rec.magic = SLOT_MARKER_MAGIC;
  rec.version = SLOT_MARKER_VERSION;
  rec.state = state;
  rec.seq = max_seq + 1;
  rec.active = active;
  rec.pending = pending;
  rec.crc32 = marker_crc32((const uint8_t*)&rec, MARKER_RECORD_SIZE - 4);

  const uint32_t base_phys = (uint32_t)(uintptr_t)__slot_marker_start - AP_FLASH_XIP_ADDR;
  const uint32_t target_phys = base_phys + (uint32_t)target * MARKER_SECTOR_SIZE;

  const uint32_t saved_start = toit_ap_image_modify_start;
  const uint32_t saved_end = toit_ap_image_modify_end;
  toit_ap_image_modify_start = base_phys;
  toit_ap_image_modify_end = base_phys + 2u * MARKER_SECTOR_SIZE;

  bool ok = BSP_QSPI_Erase_Safe(target_phys, MARKER_SECTOR_SIZE) == QSPI_OK;
  if (ok) {
    ok = BSP_QSPI_Write_Safe((uint8_t*)&rec, target_phys, sizeof(rec)) == QSPI_OK;
  }

  toit_ap_image_modify_start = saved_start;
  toit_ap_image_modify_end = saved_end;
  return ok;
}
