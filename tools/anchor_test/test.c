// Copyright (C) 2026 Toit contributors.
//
// Host unit test for anchor.c and its boot-state/partition-table record.
// Backs the two sectors with
// a RAM buffer and a fault-injectable flash emulator, then asserts the
// power-fail-safe invariants:
//   - ping-pong picks the higher-seq valid record;
//   - a torn (partial) write fails CRC and the *other* sector is used —
//     for the boot state AND the table it carries;
//   - an erase-then-crash (target sector blank) falls back to the other;
//   - fresh/erased flash: boot state defaults to slot A, but the table
//     read returns 0 — the no-boot condition the dispatcher halts on;
//   - a plain state flip preserves the stored table verbatim;
//   - table bounds (count > ANCHOR_MAX_ENTRIES) are rejected.
//
// Wired into `make ec618` next to slot_reloc_test; run manually with:
//   gcc -Wall -Wextra -O2 -I tools/anchor_test
//   -I toolchains/ec618/project/inc tools/anchor_test/test.c
//   toolchains/ec618/project/src/anchor.c
//   -o /tmp/anchor_test && /tmp/anchor_test

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "flash_rt.h"
#include "anchor.h"

#define SECTOR 0x1000u

// The "flash": the two anchor sectors. anchor.c reads it via XIP (a plain
// pointer) and writes it via the BSP emulator below.
uint8_t __toit_anchor_start[2 * SECTOR];

// Consulted by anchor.c (normally provided by sys_ro_override.c).
uint32_t toit_ap_image_modify_start = 0;
uint32_t toit_ap_image_modify_end = 0;

// Fault injection: if >= 0, the next BSP_QSPI_Write_Safe writes only this
// many bytes then "loses power" (returns OK but leaves a torn record).
static int g_torn_write_bytes = -1;
// If non-zero, the next erase succeeds but the following write is skipped
// entirely (erase-then-crash).
static int g_skip_next_write = 0;

static uint32_t base_addr(void) { return (uint32_t)(uintptr_t)__toit_anchor_start; }

uint8_t BSP_QSPI_Erase_Safe(uint32_t addr, uint32_t size) {
  uint32_t off = addr - base_addr();
  memset(__toit_anchor_start + off, 0xff, size);
  return QSPI_OK;
}

uint8_t BSP_QSPI_Write_Safe(uint8_t* data, uint32_t addr, uint32_t size) {
  if (g_skip_next_write) {
    g_skip_next_write = 0;
    return QSPI_OK;  // Power lost after erase, before write landed.
  }
  uint32_t off = addr - base_addr();
  uint32_t n = size;
  if (g_torn_write_bytes >= 0 && (uint32_t)g_torn_write_bytes < n) {
    n = (uint32_t)g_torn_write_bytes;
  }
  g_torn_write_bytes = -1;
  memcpy(__toit_anchor_start + off, data, n);
  return QSPI_OK;
}

static int g_failures = 0;
#define CHECK(cond, msg) do { \
  if (cond) { printf("  ok: %s\n", msg); } \
  else { printf("  FAIL: %s\n", msg); g_failures++; } } while (0)

static void erase_all(void) { memset(__toit_anchor_start, 0xff, sizeof(__toit_anchor_start)); }

// A small but representative table: base territory, the anchor itself,
// two slots, one data partition.
static const partition_entry test_table[] = {
  { "base",     0x024000u, 0x16C000u, PARTITION_TYPE_BASE,   {0} },
  { "littlefs", 0x191000u, 0x020000u, PARTITION_TYPE_LOCKED, {0} },
  { "anchor",   0x1B1000u, 0x002000u, PARTITION_TYPE_ANCHOR, {0} },
  { "ota-a",    0x1B3000u, 0x0C0000u, PARTITION_TYPE_SLOT,   {0} },
  { "ota-b",    0x273000u, 0x0C0000u, PARTITION_TYPE_SLOT,   {0} },
  { "registry", 0x334000u, 0x0A8000u, PARTITION_TYPE_DATA,   {0} },
};
#define TEST_TABLE_COUNT ((int)(sizeof(test_table) / sizeof(test_table[0])))

static int tables_equal(const partition_entry* a, const partition_entry* b, int n) {
  return memcmp(a, b, (size_t)n * sizeof(partition_entry)) == 0;
}

// With a region-file argument (the 8 KiB output of gen-anchor.toit), load
// it into the fake flash and validate it through the REAL device reader —
// the host-tool <-> device format compatibility check, run on every build.
static int check_region_file(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) { printf("FAIL: cannot open %s\n", path); return 1; }
  size_t n = fread(__toit_anchor_start, 1, sizeof(__toit_anchor_start), f);
  fclose(f);
  printf("provisioned region: %s (%zu bytes)\n", path, n);
  CHECK(n == sizeof(__toit_anchor_start), "region is exactly two sectors");

  slot_record r;
  partition_entry table[ANCHOR_MAX_ENTRIES];
  CHECK(anchor_read(&r), "device reader accepts the record");
  CHECK(r.active == 'A' && r.pending == 0 && r.seq == 1, "provisioning boot state A/none seq1");
  int count = anchor_table(table, ANCHOR_MAX_ENTRIES);
  CHECK(count > 0, "table present");
  int slots = 0;
  uint32_t covered = 0;
  for (int i = 0; i < count; i++) {
    if (table[i].type == PARTITION_TYPE_SLOT) slots++;
    covered += table[i].size;
  }
  CHECK(slots == 2, "two bootable slots");
  CHECK(covered == 0x400000u, "table covers the 4 MiB flash exactly");
  for (int i = 0; i < count; i++) {
    printf("  %-15.15s 0x%06x +0x%06x type=%u\n",
           table[i].name, table[i].offset, table[i].size, table[i].type);
  }
  return 0;
}

int main(int argc, char** argv) {
  if (argc > 1) {
    int rc = check_region_file(argv[1]);
    printf("\n%s (%d failure%s)\n", (rc || g_failures) ? "FAILED" : "PASSED",
           g_failures, g_failures == 1 ? "" : "s");
    return (rc || g_failures) ? 1 : 0;
  }

  slot_record r;
  partition_entry table[ANCHOR_MAX_ENTRIES];

  printf("fresh flash -> boot-state default A, but NO table\n");
  erase_all();
  CHECK(!anchor_read(&r), "no stored record");
  CHECK(r.active == 'A' && r.pending == 0, "defaults to active=A pending=0");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == 0, "table read returns 0 (no-boot condition)");

  printf("provision: write boot state + table atomically\n");
  CHECK(anchor_write_table('A', 0, SLOT_STATE_NONE, test_table, TEST_TABLE_COUNT), "write ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'A' && r.pending == 0 && r.seq == 1, "A/none seq1");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT, "table count roundtrips");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT), "table bytes roundtrip");

  printf("stage B as NEW (plain state flip) -> table PRESERVED\n");
  CHECK(anchor_write('A', 'B', SLOT_STATE_NEW), "write ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'A' && r.pending == 'B' && r.state == SLOT_STATE_NEW, "A/B/NEW");
  CHECK(r.seq == 2, "seq == 2");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT, "table still present");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT), "table bytes unchanged");

  printf("consume trial -> PENDING_VERIFY (ping-pong to other sector)\n");
  CHECK(anchor_write('A', 'B', SLOT_STATE_PENDING_VERIFY), "write ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.state == SLOT_STATE_PENDING_VERIFY && r.seq == 3, "PENDING_VERIFY seq3");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT, "table survives ping-pong");

  printf("validate -> active=B pending=0\n");
  CHECK(anchor_write('B', 0, SLOT_STATE_NONE), "write ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'B' && r.pending == 0 && r.seq == 4, "B/none seq4");

  printf("torn write: partial record fails CRC, previous record+table survive\n");
  // Current valid record is seq4. A torn write (header lands, table and
  // CRC trailer lost) must leave the reader on seq4 with the old table.
  g_torn_write_bytes = 16;
  anchor_write('A', 'B', SLOT_STATE_NEW);  // Targets the other sector.
  CHECK(anchor_read(&r), "a valid record still exists");
  CHECK(r.active == 'B' && r.seq == 4, "fell back to seq4 (torn write ignored)");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT, "old table still readable");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT), "old table bytes intact");

  printf("erase-then-crash: blank target sector, previous record survives\n");
  g_skip_next_write = 1;
  anchor_write('A', 'B', SLOT_STATE_NEW);
  CHECK(anchor_read(&r), "a valid record still exists");
  CHECK(r.active == 'B' && r.seq == 4, "fell back to seq4 (blank sector ignored)");

  printf("recovery: a real write after the failures succeeds and wins\n");
  CHECK(anchor_write('A', 'B', SLOT_STATE_NEW), "write ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'A' && r.pending == 'B' && r.seq == 5, "A/B/NEW seq5");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT, "table preserved through recovery");

  printf("layout change: write_table replaces the table atomically\n");
  partition_entry moved[TEST_TABLE_COUNT];
  memcpy(moved, test_table, sizeof(test_table));
  moved[2].offset += 0x1000;  // Shift ota-a by one sector.
  moved[3].offset += 0x1000;  // Shift ota-b by one sector.
  CHECK(anchor_write_table('A', 0, SLOT_STATE_NONE, moved, TEST_TABLE_COUNT), "write ok");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT, "table count");
  CHECK(tables_equal(table, moved, TEST_TABLE_COUNT), "moved table readable");

  printf("bounds: oversized table rejected, record untouched\n");
  CHECK(!anchor_write_table('A', 0, SLOT_STATE_NONE, test_table, ANCHOR_MAX_ENTRIES + 1),
        "count > ANCHOR_MAX_ENTRIES rejected");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT, "previous table still active");
  CHECK(tables_equal(table, moved, TEST_TABLE_COUNT), "previous table bytes intact");

  printf("strip: write_table with count 0 removes the table\n");
  CHECK(anchor_write_table('A', 0, SLOT_STATE_NONE, NULL, 0), "write ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == 0, "no table -> 0 (no fallback)");

  printf("console byte: default, set, persistence\n");
  CHECK(anchor_write_table('A', 0, SLOT_STATE_NONE, test_table, TEST_TABLE_COUNT), "reprovision");
  CHECK(anchor_console() == 0, "console defaults to 0");
  CHECK(anchor_set_console(1), "set console 1");
  CHECK(anchor_console() == 1, "console reads back 1");
  CHECK(anchor_write('A', 'B', SLOT_STATE_NEW), "state flip");
  CHECK(anchor_console() == 1, "console survives a state flip");
  CHECK(anchor_table(table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT, "table intact after console ops");
  CHECK(anchor_set_console(ANCHOR_CONSOLE_OFF), "set console off");
  CHECK(anchor_console() == ANCHOR_CONSOLE_OFF, "console off reads back");
  erase_all();
  CHECK(anchor_console() == 0, "no record -> console 0 (halt loop stays visible)");

  printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "PASSED",
         g_failures, g_failures == 1 ? "" : "s");
  return g_failures ? 1 : 0;
}
