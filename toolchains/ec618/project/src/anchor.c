// Copyright (C) 2026 Toit contributors.
//
// See anchor.h for the design. Two flash sectors hold a
// sequence-numbered, CRC-protected record; reads pick the valid record
// with the higher sequence number, writes rewrite the *other* sector.
//
// Record v3 on-flash layout:
//
//   [ header 16B ]
//   [ known-good partition_entry x active_count ]
//   [ trial partition_entry x pending_count ]
//   [ trailer 16B ]
//
// All parts are multiples of the 16-byte flash write segment. The trailer
// is { crc32 over header+entries, 12 x 0xff } and is written last as part of
// the same flash operation, so a torn write leaves an invalid record.

#include "anchor.h"

#include <string.h>

#include "flash_rt.h"  // BSP_QSPI_Erase_Safe / BSP_QSPI_Write_Safe / QSPI_OK
#include "mem_map.h"   // AP_FLASH_XIP_ADDR

// Defined in sys_ro_override.c: the writable window sysROSpaceCheck allows
// against the protected AP image. Saved and restored around our erase/write.
extern uint32_t toit_ap_image_modify_start;
extern uint32_t toit_ap_image_modify_end;

// Linker-script symbol: XIP base of the two-sector .toit_anchor region.
// Declared as an array so referring to it yields its address.
extern uint8_t __toit_anchor_start[];
extern uint8_t __toit_base_id_start[];

#define ANCHOR_SECTOR_SIZE 0x1000u
#define ANCHOR_HEADER_SIZE 16u
#define ANCHOR_TRAILER_SIZE 16u

// The on-flash record header. The entry arrays immediately after it are
// known-good first, trial second.
typedef struct {
  uint16_t magic;           // ANCHOR_MAGIC.
  uint8_t version;          // ANCHOR_VERSION.
  uint8_t state;            // One of SLOT_STATE_*.
  uint32_t seq;             // Monotonic; the higher valid record wins.
  uint8_t active;           // 'A'/'B': known-good slot.
  uint8_t pending;          // 'A'/'B', or 0.
  uint8_t active_count;     // Known-good table entries.
  uint8_t pending_count;    // Trial table entries; zero without a trial.
  uint8_t active_console;   // Known-good console.
  uint8_t pending_console;  // Trial console.
  uint8_t reserved[2];
} anchor_header;

_Static_assert(sizeof(anchor_header) == ANCHOR_HEADER_SIZE,
               "anchor_header must be exactly one 16-byte flash segment");
_Static_assert(sizeof(partition_entry) == 32,
               "partition_entry must be two 16-byte flash segments");

// RAM staging buffer for whole-record writes (flash writes cannot source
// from XIP — the write disables it). Callers hold program mode, which
// serializes anchor writes, so a single static buffer is safe.
#define ANCHOR_MAX_RECORD_SIZE                                             \
  (ANCHOR_HEADER_SIZE + 2 * ANCHOR_MAX_ENTRIES * sizeof(partition_entry) + \
   ANCHOR_TRAILER_SIZE)
_Static_assert(ANCHOR_MAX_RECORD_SIZE <= ANCHOR_SECTOR_SIZE,
               "maximum anchor record must fit one sector");
static uint8_t anchor_staging[ANCHOR_MAX_RECORD_SIZE] __attribute__((aligned(4)));

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

static bool valid_slot(uint8_t slot) {
  return slot == 'A' || slot == 'B';
}

static bool valid_console(uint8_t console) {
  return console <= 2 || console == ANCHOR_CONSOLE_OFF;
}

// Version-3 partition tables cover the EC618's physical flash, in order.
#define ANCHOR_FLASH_END 0x400000u
#define ANCHOR_AP_OFFSET 0x24000u

// Names are nonempty UTF-8 followed by NUL padding, at most 15 bytes.
// Keep the decoder bounded: these bytes may have come directly from flash.
static bool valid_name(const char name[16]) {
  unsigned len = 0;
  while (len < 16 && name[len] != 0) len++;
  if (len == 0 || len == 16) return false;
  for (unsigned i = len; i < 16; i++) {
    if (name[i] != 0) return false;
  }
  for (unsigned i = 0; i < len;) {
    uint8_t first = (uint8_t)name[i++];
    if (first < 0x80) continue;
    unsigned remaining;
    uint32_t value, minimum;
    if (first >= 0xc2 && first <= 0xdf) {
      remaining = 1; value = first & 0x1f; minimum = 0x80;
    } else if (first >= 0xe0 && first <= 0xef) {
      remaining = 2; value = first & 0x0f; minimum = 0x800;
    } else if (first >= 0xf0 && first <= 0xf4) {
      remaining = 3; value = first & 7; minimum = 0x10000;
    } else {
      return false;
    }
    if (remaining > len - i) return false;
    while (remaining-- != 0) {
      uint8_t next = (uint8_t)name[i++];
      if ((next & 0xc0) != 0x80) return false;
      value = (value << 6) | (next & 0x3f);
    }
    if (value < minimum || value > 0x10ffff ||
        (value >= 0xd800 && value <= 0xdfff)) return false;
  }
  return true;
}

static bool valid_table(const partition_entry* table, int count) {
  if (table == NULL || count <= 0 || count > ANCHOR_MAX_ENTRIES) return false;
  const partition_entry* base = NULL;
  const partition_entry* base_id = NULL;
  const partition_entry* anchor = NULL;
  const partition_entry* slots[2] = {NULL, NULL};
  const partition_entry* registry = NULL;
  int slot_count = 0;
  uint32_t cursor = 0;
  for (int i = 0; i < count; i++) {
    const partition_entry* p = &table[i];
    if (!valid_name(p->name) || p->type < PARTITION_TYPE_LOCKED ||
        p->type > PARTITION_TYPE_FREE) return false;
    for (int j = 0; j < i; j++) {
      if (strcmp(p->name, table[j].name) == 0) return false;
    }
    if (p->offset != cursor || p->size == 0 ||
        p->offset % ANCHOR_SECTOR_SIZE != 0 ||
        p->size % ANCHOR_SECTOR_SIZE != 0 ||
        p->size > ANCHOR_FLASH_END - cursor) return false;
    cursor += p->size;  // The subtraction above bounds this sum.
    switch (p->type) {
      case PARTITION_TYPE_BASE:
        if (base != NULL || strcmp(p->name, "base") != 0) return false;
        base = p;
        break;
      case PARTITION_TYPE_BASE_ID:
        if (base_id != NULL || strcmp(p->name, "base-id") != 0) return false;
        base_id = p;
        break;
      case PARTITION_TYPE_ANCHOR:
        if (anchor != NULL || strcmp(p->name, "anchor") != 0) return false;
        anchor = p;
        break;
      case PARTITION_TYPE_SLOT:
        if (slot_count == 2) return false;
        slots[slot_count++] = p;
        break;
    }
    if (strcmp(p->name, "registry") == 0) {
      if (p->type != PARTITION_TYPE_DATA) return false;
      registry = p;
    }
  }
  if (cursor != ANCHOR_FLASH_END || base == NULL || base_id == NULL ||
      anchor == NULL || slot_count != 2 || registry == NULL) return false;
  // The base and anchor are tied to this binary's linker symbols. A table
  // cannot move either of them even if its arithmetic is self-consistent.
  uint32_t base_id_phys =
      (uint32_t)(uintptr_t)__toit_base_id_start - AP_FLASH_XIP_ADDR;
  uint32_t anchor_phys =
      (uint32_t)(uintptr_t)__toit_anchor_start - AP_FLASH_XIP_ADDR;
  return base->offset == ANCHOR_AP_OFFSET &&
         base_id->offset == base->offset + base->size &&
         base_id->offset == base_id_phys &&
         base_id->size == ANCHOR_SECTOR_SIZE &&
         anchor->offset == anchor_phys &&
         anchor->size == 2 * ANCHOR_SECTOR_SIZE &&
         anchor->offset >= base_id->offset + base_id->size &&
         slots[0]->offset >= anchor->offset + anchor->size &&
         slots[0]->size == slots[1]->size &&
         registry->offset >= slots[1]->offset + slots[1]->size;
}

// XIP address of sector `idx` (0 or 1) of the marker region.
static const uint8_t* anchor_sector_xip(int idx) {
  return (const uint8_t*)((uintptr_t)__toit_anchor_start +
                          (uintptr_t)idx * ANCHOR_SECTOR_SIZE);
}

static uint32_t record_size(uint8_t active_count, uint8_t pending_count) {
  return ANCHOR_HEADER_SIZE +
         ((uint32_t)active_count + pending_count) * sizeof(partition_entry) +
         ANCHOR_TRAILER_SIZE;
}

// Validates sector `idx` (magic, version, state, bounds, crc) and fills
// `out` with its header. Returns true for a well-formed record.
static bool anchor_read_sector(int idx, anchor_header* out) {
  const uint8_t* xip = anchor_sector_xip(idx);
  memcpy(out, xip, sizeof(*out));
  if (out->magic != ANCHOR_MAGIC || out->version != ANCHOR_VERSION)
    return false;
  if (!valid_slot(out->active) || !valid_console(out->active_console))
    return false;
  if (out->active_count == 0 || out->active_count > ANCHOR_MAX_ENTRIES ||
      out->pending_count > ANCHOR_MAX_ENTRIES) {
    return false;
  }
  if (out->pending == 0) {
    if (out->state != SLOT_STATE_NONE || out->pending_count != 0)
      return false;
  } else {
    if (!valid_slot(out->pending) || out->pending == out->active)
      return false;
    if (out->state != SLOT_STATE_NEW &&
        out->state != SLOT_STATE_PENDING_VERIFY) {
      return false;
    }
    if (out->pending_count == 0 || !valid_console(out->pending_console))
      return false;
  }
  uint32_t size = record_size(out->active_count, out->pending_count);
  if (size > ANCHOR_SECTOR_SIZE)
    return false;
  uint32_t stored_crc;
  memcpy(&stored_crc, xip + size - ANCHOR_TRAILER_SIZE, sizeof(stored_crc));
  return anchor_crc32(xip, size - ANCHOR_TRAILER_SIZE) == stored_crc;
}

// Returns the current valid sector (higher seq), or -1 if neither is valid
// or a CRC-valid record contains a malformed table. Fills `out` on success.
static int anchor_current(anchor_header* out) {
  anchor_header h0, h1;
  bool v0 = anchor_read_sector(0, &h0);
  bool v1 = anchor_read_sector(1, &h1);
  // A CRC-valid but semantically invalid record is not a torn write.
  // Refuse the configuration rather than booting an older layout whose
  // data may already have been superseded by a transaction.
  for (int i = 0; i < 2; i++) {
    if (!(i == 0 ? v0 : v1)) continue;
    const anchor_header* h = i == 0 ? &h0 : &h1;
    const partition_entry* table = (const partition_entry*)(
        anchor_sector_xip(i) + ANCHOR_HEADER_SIZE);
    if (!valid_table(table, h->active_count) ||
        (h->pending_count != 0 &&
         !valid_table(table + h->active_count, h->pending_count))) return -1;
  }
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

static const partition_entry* active_table_xip(int sector) {
  return (const partition_entry*)(anchor_sector_xip(sector) +
                                  ANCHOR_HEADER_SIZE);
}

static const partition_entry* pending_table_xip(int sector,
                                                const anchor_header* header) {
  return active_table_xip(sector) + header->active_count;
}

static int copy_table(const partition_entry* source,
                      int count,
                      partition_entry* out,
                      int max) {
  if (count > max)
    count = max;
  if (count > 0) {
    memcpy(out, source, (size_t)count * sizeof(partition_entry));
  }
  return count;
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

  // No usable configuration: default boot state, but table reads return
  // zero so the dispatcher halts instead of using an implicit flash layout.
  memset(out, 0, sizeof(*out));
  out->state = SLOT_STATE_NONE;
  out->seq = 0;
  out->active = 'A';
  return false;
}

uint8_t anchor_boot_console(void) {
  anchor_header h;
  if (anchor_current(&h) < 0) {
    return 0;  // Unprovisioned: keep the halt loop visible on UART0.
  }
  return h.pending != 0 && h.state == SLOT_STATE_NEW ? h.pending_console
                                                     : h.active_console;
}

uint8_t anchor_console_for_slot(uint8_t slot) {
  anchor_header h;
  if (anchor_current(&h) < 0)
    return 0;
  return h.pending != 0 && slot == h.pending ? h.pending_console
                                             : h.active_console;
}

int anchor_table_for_slot(uint8_t slot, partition_entry* out, int max) {
  if (max < 0 || (max > 0 && out == NULL))
    return 0;
  anchor_header h;
  int current = anchor_current(&h);
  if (current < 0)
    return 0;
  if (h.pending != 0 && slot == h.pending) {
    return copy_table(pending_table_xip(current, &h), h.pending_count, out,
                      max);
  }
  return copy_table(active_table_xip(current), h.active_count, out, max);
}

static bool anchor_write_full(uint8_t active,
                              uint8_t pending,
                              uint8_t state,
                              const partition_entry* active_table,
                              int active_count,
                              uint8_t active_console,
                              const partition_entry* pending_table,
                              int pending_count,
                              uint8_t pending_console) {
  if (!valid_slot(active) || !valid_console(active_console))
    return false;
  if (active_count < 0 || active_count > ANCHOR_MAX_ENTRIES)
    return false;
  if (active_count > 0 && active_table == NULL)
    return false;
  if (pending == 0) {
    if (state != SLOT_STATE_NONE || pending_count != 0)
      return false;
  } else {
    if (!valid_slot(pending) || pending == active)
      return false;
    if (state != SLOT_STATE_NEW && state != SLOT_STATE_PENDING_VERIFY)
      return false;
    if (pending_count <= 0 || pending_count > ANCHOR_MAX_ENTRIES ||
        pending_table == NULL || !valid_console(pending_console)) {
      return false;
    }
  }

  if (!valid_table(active_table, active_count) ||
      (pending_count != 0 && !valid_table(pending_table, pending_count)))
    return false;

  anchor_header current_header;
  int current = anchor_current(&current_header);
  uint32_t max_seq = current >= 0 ? current_header.seq : 0;
  // Wrapping to zero would leave the older UINT32_MAX record selected
  // even though the caller was told that its transition succeeded.
  if (max_seq == UINT32_MAX) return false;
  // Write to the sector that is NOT current valid, so the live record
  // survives a torn erase/write. (current == -1 => sector 0.)
  int target = current == 0 ? 1 : 0;

  // Stage the whole record in RAM before the flash operation, since either
  // table may point into XIP and the write disables XIP.
  uint32_t size = record_size((uint8_t)active_count, (uint8_t)pending_count);
  memset(anchor_staging, 0xff, size);
  anchor_header* header = (anchor_header*)anchor_staging;
  memset(header, 0, sizeof(*header));
  header->magic = ANCHOR_MAGIC;
  header->version = ANCHOR_VERSION;
  header->state = state;
  header->seq = max_seq + 1;
  header->active = active;
  header->pending = pending;
  header->active_count = (uint8_t)active_count;
  header->pending_count = (uint8_t)pending_count;
  header->active_console = active_console;
  header->pending_console = pending_console;

  uint8_t* entries = anchor_staging + ANCHOR_HEADER_SIZE;
  if (active_count > 0) {
    memcpy(entries, active_table,
           (size_t)active_count * sizeof(partition_entry));
  }
  if (pending_count > 0) {
    memcpy(entries + (size_t)active_count * sizeof(partition_entry),
           pending_table, (size_t)pending_count * sizeof(partition_entry));
  }
  uint32_t crc = anchor_crc32(anchor_staging, size - ANCHOR_TRAILER_SIZE);
  memcpy(anchor_staging + size - ANCHOR_TRAILER_SIZE, &crc, sizeof(crc));

  const uint32_t base_phys =
      (uint32_t)(uintptr_t)__toit_anchor_start - AP_FLASH_XIP_ADDR;
  const uint32_t target_phys =
      base_phys + (uint32_t)target * ANCHOR_SECTOR_SIZE;

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

bool anchor_write_table(uint8_t active,
                        uint8_t pending,
                        uint8_t state,
                        const partition_entry* table,
                        int count) {
  if (pending != 0 || state != SLOT_STATE_NONE)
    return false;
  return anchor_write_full(active, 0, SLOT_STATE_NONE, table, count, 0, NULL, 0,
                           ANCHOR_CONSOLE_OFF);
}

bool anchor_stage_table(uint8_t active,
                        uint8_t pending,
                        const partition_entry* table,
                        int count,
                        uint8_t console) {
  anchor_header h;
  int current = anchor_current(&h);
  if (current < 0 || h.pending != 0 || h.state != SLOT_STATE_NONE)
    return false;
  if (active != h.active || !valid_slot(pending) || pending == active)
    return false;
  return anchor_write_full(active, pending, SLOT_STATE_NEW,
                           active_table_xip(current), h.active_count,
                           h.active_console, table, count, console);
}

bool anchor_stage(uint8_t active, uint8_t pending) {
  anchor_header h;
  int current = anchor_current(&h);
  if (current < 0 || h.pending != 0 || h.state != SLOT_STATE_NONE)
    return false;
  if (active != h.active || !valid_slot(pending) || pending == active)
    return false;
  return anchor_stage_table(active, pending, active_table_xip(current),
                            h.active_count, h.active_console);
}

bool anchor_set_pending_console(uint8_t console) {
  if (!valid_console(console))
    return false;
  anchor_header h;
  int current = anchor_current(&h);
  if (current < 0 || h.pending == 0 || h.state != SLOT_STATE_NEW)
    return false;
  return anchor_write_full(h.active, h.pending, h.state,
                           active_table_xip(current), h.active_count,
                           h.active_console, pending_table_xip(current, &h),
                           h.pending_count, console);
}

bool anchor_consume_trial(uint8_t active, uint8_t pending) {
  anchor_header h;
  int current = anchor_current(&h);
  if (current < 0 || h.state != SLOT_STATE_NEW || h.active != active ||
      h.pending != pending) {
    return false;
  }
  return anchor_write_full(h.active, h.pending, SLOT_STATE_PENDING_VERIFY,
                           active_table_xip(current), h.active_count,
                           h.active_console, pending_table_xip(current, &h),
                           h.pending_count, h.pending_console);
}

bool anchor_validate(uint8_t slot) {
  anchor_header h;
  int current = anchor_current(&h);
  if (current < 0)
    return false;
  if (h.pending == 0) {
    // Re-validating the already-known-good slot is an idempotent record write.
    if (slot != h.active)
      return false;
    return anchor_write_full(h.active, 0, SLOT_STATE_NONE,
                             active_table_xip(current), h.active_count,
                             h.active_console, NULL, 0, ANCHOR_CONSOLE_OFF);
  }
  if (slot != h.pending || h.state != SLOT_STATE_PENDING_VERIFY)
    return false;
  return anchor_write_full(h.pending, 0, SLOT_STATE_NONE,
                           pending_table_xip(current, &h), h.pending_count,
                           h.pending_console, NULL, 0, ANCHOR_CONSOLE_OFF);
}

bool anchor_rollback(void) {
  anchor_header h;
  int current = anchor_current(&h);
  if (current < 0 || h.pending == 0)
    return false;
  return anchor_write_full(h.active, 0, SLOT_STATE_NONE,
                           active_table_xip(current), h.active_count,
                           h.active_console, NULL, 0, ANCHOR_CONSOLE_OFF);
}
