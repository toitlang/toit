// Copyright (C) 2026 Toit contributors.
//
// Host unit test for anchor.c and its transactional image configuration.
// Backs the two sectors with
// a RAM buffer and a fault-injectable flash emulator, then asserts the
// power-fail-safe invariants:
//   - ping-pong picks the higher-seq valid record;
//   - a torn (partial) write fails CRC and the *other* sector is used —
//     for the boot state AND both configurations it carries;
//   - an erase-then-crash (target sector blank) falls back to the other;
//   - fresh/erased flash: boot state defaults to slot A, but the table
//     read returns 0 — the no-boot condition the dispatcher halts on;
//   - a trial carries its own table+console, promoted on validation and
//     discarded on rollback;
//   - console/layout changes without a freshly staged trial are rejected;
//   - per-configuration table bounds are rejected.
//
// Wired into `make ec618` next to slot_reloc_test; run manually with:
//   gcc -Wall -Wextra -O2 -I tools/anchor_test
//   -I toolchains/ec618/project/inc tools/anchor_test/test.c
//   toolchains/ec618/project/src/anchor.c
//   -o /tmp/anchor_test && /tmp/anchor_test

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "anchor.h"
#include "flash_rt.h"

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

static uint32_t base_addr(void) {
  return (uint32_t)(uintptr_t)__toit_anchor_start;
}

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
#define CHECK(cond, msg)           \
  do {                             \
    if (cond) {                    \
      printf("  ok: %s\n", msg);   \
    } else {                       \
      printf("  FAIL: %s\n", msg); \
      g_failures++;                \
    }                              \
  } while (0)

static void erase_all(void) {
  memset(__toit_anchor_start, 0xff, sizeof(__toit_anchor_start));
}

// A small but representative table: base territory, the anchor itself,
// two slots, one data partition.
static const partition_entry test_table[] = {
    {"base", 0x024000u, 0x16C000u, PARTITION_TYPE_BASE, {0}},
    {"littlefs", 0x191000u, 0x020000u, PARTITION_TYPE_LOCKED, {0}},
    {"anchor", 0x1B1000u, 0x002000u, PARTITION_TYPE_ANCHOR, {0}},
    {"ota-a", 0x1B3000u, 0x0C0000u, PARTITION_TYPE_SLOT, {0}},
    {"ota-b", 0x273000u, 0x0C0000u, PARTITION_TYPE_SLOT, {0}},
    {"registry", 0x334000u, 0x0A8000u, PARTITION_TYPE_DATA, {0}},
};
#define TEST_TABLE_COUNT ((int)(sizeof(test_table) / sizeof(test_table[0])))

static int tables_equal(const partition_entry* a,
                        const partition_entry* b,
                        int n) {
  return memcmp(a, b, (size_t)n * sizeof(partition_entry)) == 0;
}

// With a region-file argument (the 8 KiB output of gen-anchor.toit), load
// it into the fake flash and validate it through the REAL device reader —
// the host-tool <-> device format compatibility check, run on every build.
static int check_region_file(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) {
    printf("FAIL: cannot open %s\n", path);
    return 1;
  }
  size_t n = fread(__toit_anchor_start, 1, sizeof(__toit_anchor_start), f);
  fclose(f);
  printf("provisioned region: %s (%zu bytes)\n", path, n);
  CHECK(n == sizeof(__toit_anchor_start), "region is exactly two sectors");

  slot_record r;
  partition_entry table[ANCHOR_MAX_ENTRIES];
  CHECK(anchor_read(&r), "device reader accepts the record");
  CHECK(r.active == 'A' && r.pending == 0 && r.seq == 1,
        "provisioning boot state A/none seq1");
  int count = anchor_table_for_slot('A', table, ANCHOR_MAX_ENTRIES);
  CHECK(count > 0, "table present");
  CHECK(anchor_boot_console() == 0, "known-good console is UART0");
  int slots = 0;
  uint32_t covered = 0;
  for (int i = 0; i < count; i++) {
    if (table[i].type == PARTITION_TYPE_SLOT)
      slots++;
    covered += table[i].size;
  }
  CHECK(slots == 2, "two bootable slots");
  CHECK(covered == 0x400000u, "table covers the 4 MiB flash exactly");
  for (int i = 0; i < count; i++) {
    printf("  %-15.15s 0x%06x +0x%06x type=%u\n", table[i].name,
           table[i].offset, table[i].size, table[i].type);
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
  CHECK(anchor_table_for_slot('A', table, ANCHOR_MAX_ENTRIES) == 0,
        "table read returns 0 (no-boot condition)");
  CHECK(anchor_boot_console() == 0, "fresh-flash boot console is UART0");

  printf("provision: write known-good image configuration atomically\n");
  CHECK(
      anchor_write_table('A', 0, SLOT_STATE_NONE, test_table, TEST_TABLE_COUNT),
      "write ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'A' && r.pending == 0 && r.seq == 1, "A/none seq1");
  CHECK(
      anchor_table_for_slot('A', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "table count roundtrips");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT),
        "table bytes roundtrip");
  CHECK(!anchor_set_pending_console(1),
        "console change without a freshly staged OTA is rejected");

  printf("stage B as NEW -> clone active config, then edit pending console\n");
  CHECK(anchor_stage('A', 'B'), "stage ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'A' && r.pending == 'B' && r.state == SLOT_STATE_NEW,
        "A/B/NEW");
  CHECK(r.seq == 2, "seq == 2");
  CHECK(
      anchor_table_for_slot('A', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "known-good table present");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT),
        "known-good table unchanged");
  CHECK(
      anchor_table_for_slot('B', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "trial table present");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT),
        "trial table cloned");
  CHECK(anchor_set_pending_console(1), "pending console set to UART1");
  CHECK(anchor_boot_console() == 1, "NEW boot candidate uses trial console");
  CHECK(anchor_console_for_slot('A') == 0, "known-good console remains UART0");
  CHECK(anchor_console_for_slot('B') == 1, "trial console is UART1");

  printf("consume trial -> PENDING_VERIFY, preserving both configs\n");
  CHECK(anchor_consume_trial('A', 'B'), "consume ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.state == SLOT_STATE_PENDING_VERIFY && r.seq == 4,
        "PENDING_VERIFY seq4");
  CHECK(anchor_boot_console() == 0,
        "next boot after an unvalidated trial selects known-good console");
  CHECK(anchor_console_for_slot('B') == 1,
        "running trial still resolves its own console");

  printf("validate -> atomically promote B table+console\n");
  CHECK(anchor_validate('B'), "validate ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'B' && r.pending == 0 && r.seq == 5, "B/none seq5");
  CHECK(anchor_boot_console() == 1, "promoted console is UART1");
  CHECK(
      anchor_table_for_slot('B', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "promoted table present");

  printf("torn stage: previous known-good config survives\n");
  g_torn_write_bytes = 16;
  anchor_stage('B', 'A');
  CHECK(anchor_read(&r), "a valid record still exists");
  CHECK(r.active == 'B' && r.seq == 5,
        "fell back to seq5 (torn write ignored)");
  CHECK(
      anchor_table_for_slot('B', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "known-good table still readable");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT),
        "old table bytes intact");
  CHECK(anchor_boot_console() == 1, "known-good console survives torn stage");

  printf("erase-then-crash: blank target sector, previous record survives\n");
  g_skip_next_write = 1;
  anchor_stage('B', 'A');
  CHECK(anchor_read(&r), "a valid record still exists");
  CHECK(r.active == 'B' && r.seq == 5,
        "fell back to seq5 (blank sector ignored)");

  printf("future layout transaction: stage A with a distinct table+console\n");
  partition_entry moved[TEST_TABLE_COUNT];
  memcpy(moved, test_table, sizeof(test_table));
  moved[3].offset += 0x1000;  // Shift ota-a by one sector.
  moved[4].offset += 0x1000;  // Shift ota-b by one sector.
  CHECK(!anchor_stage_table('B', 'A', test_table, ANCHOR_MAX_ENTRIES + 1, 2),
        "count > ANCHOR_MAX_ENTRIES rejected");
  CHECK(anchor_read(&r) && r.pending == 0,
        "oversized table did not start a transaction");
  CHECK(anchor_stage_table('B', 'A', moved, TEST_TABLE_COUNT, 2),
        "stage-table ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'B' && r.pending == 'A' && r.state == SLOT_STATE_NEW,
        "B/A/NEW");
  CHECK(
      anchor_table_for_slot('B', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "known-good table retained during layout trial");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT),
        "known-good table bytes retained");
  CHECK(
      anchor_table_for_slot('A', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "trial table readable");
  CHECK(tables_equal(table, moved, TEST_TABLE_COUNT), "trial table differs");
  CHECK(anchor_console_for_slot('B') == 1, "known-good console retained");
  CHECK(anchor_console_for_slot('A') == 2, "trial console attached to A");

  printf("torn validation: both configurations survive\n");
  CHECK(anchor_consume_trial('B', 'A'), "consume layout trial");
  g_torn_write_bytes = 16;
  anchor_validate('A');
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'B' && r.pending == 'A' &&
            r.state == SLOT_STATE_PENDING_VERIFY,
        "torn validation leaves trial pending");
  CHECK(
      anchor_table_for_slot('B', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "known-good table survived torn validation");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT),
        "known-good bytes survived torn validation");
  CHECK(
      anchor_table_for_slot('A', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "trial table survived torn validation");
  CHECK(tables_equal(table, moved, TEST_TABLE_COUNT),
        "trial bytes survived torn validation");

  printf("rollback: discard trial config and retain known-good config\n");
  CHECK(anchor_rollback(), "rollback ok");
  CHECK(anchor_read(&r), "record found");
  CHECK(r.active == 'B' && r.pending == 0 && r.state == SLOT_STATE_NONE,
        "B/none after rollback");
  CHECK(anchor_boot_console() == 1, "rollback restored UART1");
  CHECK(
      anchor_table_for_slot('B', table, ANCHOR_MAX_ENTRIES) == TEST_TABLE_COUNT,
      "rollback table present");
  CHECK(tables_equal(table, test_table, TEST_TABLE_COUNT),
        "rollback restored known-good table");

  printf("provisioning API rejects transactional state\n");
  CHECK(!anchor_write_table('A', 'B', SLOT_STATE_NEW, test_table,
                            TEST_TABLE_COUNT),
        "write_table cannot create a trial");

  erase_all();
  CHECK(anchor_boot_console() == 0,
        "no record -> console 0 (halt loop stays visible)");

  printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "PASSED", g_failures,
         g_failures == 1 ? "" : "s");
  return g_failures ? 1 : 0;
}
