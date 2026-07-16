// Copyright (C) 2026 Toit contributors.
//
// See anchor.h for the design. Two flash sectors hold a
// sequence-numbered, CRC-protected record; reads pick the valid record
// with the higher sequence number, writes rewrite the *other* sector.
//
// Record v2 on-flash layout (docs/partition-table-design.md §0.1) — all
// three parts are multiples of the 16-byte flash write segment, and the
// CRC trailer is written with the same single write as the rest, sitting
// last so a torn write leaves an invalid record:
//
//   [ header 16B ][ partition_entry x N, 32B each ][ trailer 16B ]
//
// The trailer is { crc32 over header+entries, 12 x 0xff }.

#include "anchor.h"

#include <string.h>

#include "flash_rt.h"   // BSP_QSPI_Erase_Safe / BSP_QSPI_Write_Safe / QSPI_OK
#include "mem_map.h"    // AP_FLASH_XIP_ADDR

// Defined in sys_ro_override.c: the writable window sysROSpaceCheck allows
// against the protected AP image. Saved and restored around our erase/write.
extern uint32_t toit_ap_image_modify_start;
extern uint32_t toit_ap_image_modify_end;

// Linker-script symbol: XIP base of the two-sector .toit_anchor region.
// Declared as an array so referring to it yields its address.
extern uint8_t __toit_anchor_start[];

#define ANCHOR_SECTOR_SIZE 0x1000u
#define ANCHOR_HEADER_SIZE 16u
#define ANCHOR_TRAILER_SIZE 16u

// The on-flash record header.
typedef struct {
  uint16_t magic;       // ANCHOR_MAGIC.
  uint8_t version;      // ANCHOR_VERSION.
  uint8_t state;        // One of SLOT_STATE_*.
  uint32_t seq;         // Monotonic; the higher valid record wins.
  uint8_t active;       // 'A'/'B'.
  uint8_t pending;      // 'A'/'B', or 0.
  uint8_t table_count;  // Entries after the header; 0 = no table.
  uint8_t reserved[5];
} anchor_header;

_Static_assert(sizeof(anchor_header) == ANCHOR_HEADER_SIZE,
               "anchor_header must be exactly one 16-byte flash segment");
_Static_assert(sizeof(partition_entry) == 32,
               "partition_entry must be two 16-byte flash segments");

// RAM staging buffer for whole-record writes (flash writes cannot source
// from XIP — the write disables it). Callers hold program mode, which
// serializes marker writes, so a single static buffer is safe.
#define ANCHOR_MAX_RECORD_SIZE \
  (ANCHOR_HEADER_SIZE + ANCHOR_MAX_ENTRIES * sizeof(partition_entry) + ANCHOR_TRAILER_SIZE)
static uint8_t anchor_staging[ANCHOR_MAX_RECORD_SIZE];

// Standard CRC-32 (poly 0xEDB88320), computed bitwise — record-sized
// inputs at boot/OTA frequency don't justify a table in .rodata.
static uint32_t anchor_crc32(const uint8_t* data, uint32_t len) {
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
static const uint8_t* anchor_sector_xip(int idx) {
  return (const uint8_t*)((uintptr_t)__toit_anchor_start + (uintptr_t)idx * ANCHOR_SECTOR_SIZE);
}

static uint32_t record_size(uint8_t table_count) {
  return ANCHOR_HEADER_SIZE + (uint32_t)table_count * sizeof(partition_entry)
      + ANCHOR_TRAILER_SIZE;
}

// Validates sector `idx` (magic, version, bounds, crc) and fills `out`
// with its header. Returns true for a well-formed record.
static bool anchor_read_sector(int idx, anchor_header* out) {
  const uint8_t* xip = anchor_sector_xip(idx);
  memcpy(out, xip, sizeof(*out));
  if (out->magic != ANCHOR_MAGIC) return false;
  if (out->version != ANCHOR_VERSION) return false;
  uint32_t size = record_size(out->table_count);
  if (size > ANCHOR_SECTOR_SIZE) return false;
  uint32_t stored_crc;
  memcpy(&stored_crc, xip + size - ANCHOR_TRAILER_SIZE, sizeof(stored_crc));
  return anchor_crc32(xip, size - ANCHOR_TRAILER_SIZE) == stored_crc;
}

// Returns the sector index holding the current valid record (higher seq),
// or -1 if neither sector is valid. Fills `out` with its header.
static int anchor_current(anchor_header* out) {
  anchor_header h0, h1;
  bool v0 = anchor_read_sector(0, &h0);
  bool v1 = anchor_read_sector(1, &h1);
  if (v0 && (!v1 || h0.seq >= h1.seq)) {
    *out = h0;
    return 0;
  }
  if (v1) {
    *out = h1;
    return 1;
  }
  return -1;
}

bool anchor_read(slot_record* out) {
  anchor_header h;
  int current = anchor_current(&h);
  if (current >= 0) {
    out->state = h.state;
    out->seq = h.seq;
    out->active = h.active;
    out->pending = h.pending;
    return true;
  }

  // Fresh flash (both sectors erased/garbage): default to slot A, no trial.
  // Matches the pre-rollback behaviour where an erased marker meant slot A.
  memset(out, 0, sizeof(*out));
  out->state = SLOT_STATE_NONE;
  out->seq = 0;
  out->active = 'A';
  out->pending = 0;
  return false;
}

int anchor_table(partition_entry* out, int max) {
  anchor_header h;
  int current = anchor_current(&h);
  if (current < 0 || h.table_count == 0) return 0;  // No fallback by design.
  int count = h.table_count;
  if (count > max) count = max;
  memcpy(out, anchor_sector_xip(current) + ANCHOR_HEADER_SIZE,
         (size_t)count * sizeof(partition_entry));
  return count;
}

bool anchor_write_table(uint8_t active, uint8_t pending, uint8_t state,
                             const partition_entry* table, int count) {
  if (count < 0 || count > ANCHOR_MAX_ENTRIES) return false;
  if (count > 0 && table == NULL) return false;

  anchor_header current_header;
  int current = anchor_current(&current_header);
  uint32_t max_seq = (current >= 0) ? current_header.seq : 0;
  // Write to the sector that is NOT current valid, so the live record
  // survives a torn erase/write. (current == -1 ⇒ neither valid ⇒ sector 0.)
  int target = (current == 0) ? 1 : 0;

  // Stage the whole record in RAM: the source of a flash write cannot be
  // XIP (the write disables it), and `table` may point into flash.
  uint32_t size = record_size((uint8_t)count);
  memset(anchor_staging, 0xff, size);
  anchor_header* header = (anchor_header*)anchor_staging;
  memset(header, 0, sizeof(*header));
  header->magic = ANCHOR_MAGIC;
  header->version = ANCHOR_VERSION;
  header->state = state;
  header->seq = max_seq + 1;
  header->active = active;
  header->pending = pending;
  header->table_count = (uint8_t)count;
  if (count > 0) {
    memcpy(anchor_staging + ANCHOR_HEADER_SIZE, table,
           (size_t)count * sizeof(partition_entry));
  }
  uint32_t crc = anchor_crc32(anchor_staging, size - ANCHOR_TRAILER_SIZE);
  memcpy(anchor_staging + size - ANCHOR_TRAILER_SIZE, &crc, sizeof(crc));

  const uint32_t base_phys = (uint32_t)(uintptr_t)__toit_anchor_start - AP_FLASH_XIP_ADDR;
  const uint32_t target_phys = base_phys + (uint32_t)target * ANCHOR_SECTOR_SIZE;

  const uint32_t saved_start = toit_ap_image_modify_start;
  const uint32_t saved_end = toit_ap_image_modify_end;
  toit_ap_image_modify_start = base_phys;
  toit_ap_image_modify_end = base_phys + 2u * ANCHOR_SECTOR_SIZE;

  bool ok = BSP_QSPI_Erase_Safe(target_phys, ANCHOR_SECTOR_SIZE) == QSPI_OK;
  if (ok) {
    ok = BSP_QSPI_Write_Safe(anchor_staging, target_phys, size) == QSPI_OK;
  }

  toit_ap_image_modify_start = saved_start;
  toit_ap_image_modify_end = saved_end;
  return ok;
}

bool anchor_write(uint8_t active, uint8_t pending, uint8_t state) {
  // Preserve the stored table across the boot-state flip. A record
  // without a table stays without one (count 0), so plain state flips
  // never bake a layout in.
  static partition_entry preserved[ANCHOR_MAX_ENTRIES];
  anchor_header h;
  int current = anchor_current(&h);
  int count = 0;
  if (current >= 0 && h.table_count > 0) {
    count = h.table_count;
    if (count > ANCHOR_MAX_ENTRIES) return false;  // Unreachable: read validated size.
    memcpy(preserved, anchor_sector_xip(current) + ANCHOR_HEADER_SIZE,
           (size_t)count * sizeof(partition_entry));
  }
  return anchor_write_table(active, pending, state,
                                 count > 0 ? preserved : NULL, count);
}
