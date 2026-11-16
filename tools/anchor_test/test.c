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
#include "mem_map.h"

#define SECTOR 0x1000u

// The "flash": the two anchor sectors. anchor.c reads it via XIP (a plain
// pointer) and writes it via the BSP emulator below.
_Alignas(uint32_t) uint8_t __toit_anchor_start[2 * SECTOR];
// Address-only linker symbol: the emulator never dereferences the base-id.
__asm__(".globl __toit_base_id_start\n"
        ".set __toit_base_id_start, __toit_anchor_start - 0x21000\n");

// Consulted by anchor.c (normally provided by sys_ro_override.c).
uint32_t toit_ap_image_modify_start = 0;
uint32_t toit_ap_image_modify_end = 0;

// Fault injection: if >= 0, the next BSP_QSPI_Write_Safe writes only this
// many bytes then "loses power" (returns OK but leaves a torn record).
static int g_torn_write_bytes = -1;
// If non-zero, the next erase succeeds but the following write is skipped
// entirely (erase-then-crash).
static int g_skip_next_write = 0;
static unsigned g_erases = 0;
static unsigned g_writes = 0;

static uint32_t base_addr(void) {
  return (uint32_t)(uintptr_t)__toit_anchor_start - AP_FLASH_XIP_ADDR;
}

uint8_t BSP_QSPI_Erase_Safe(uint32_t addr, uint32_t size) {
  g_erases++;
  uint32_t off = addr - base_addr();
  memset(__toit_anchor_start + off, 0xff, size);
  return QSPI_OK;
}

uint8_t BSP_QSPI_Write_Safe(uint8_t* data, uint32_t addr, uint32_t size) {
  g_writes++;
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

// Complete default layout, including the frozen vendor reservations.
static const partition_entry test_table[] = {
    {"headers", 0x000000u, 0x004000u, PARTITION_TYPE_LOCKED, {0}},
    {"bootloader", 0x004000u, 0x020000u, PARTITION_TYPE_LOCKED, {0}},
    {"base", 0x024000u, 0x16C000u, PARTITION_TYPE_BASE, {0}},
    {"base-id", 0x190000u, 0x001000u, PARTITION_TYPE_BASE_ID, {0}},
    {"littlefs", 0x191000u, 0x020000u, PARTITION_TYPE_LOCKED, {0}},
    {"anchor", 0x1B1000u, 0x002000u, PARTITION_TYPE_ANCHOR, {0}},
    {"ota-a", 0x1B3000u, 0x0C0000u, PARTITION_TYPE_SLOT, {0}},
    {"ota-b", 0x273000u, 0x0C0000u, PARTITION_TYPE_SLOT, {0}},
    {"free", 0x333000u, 0x001000u, PARTITION_TYPE_FREE, {0}},
    {"registry", 0x334000u, 0x0A8000u, PARTITION_TYPE_DATA, {0}},
    {"nvram-factory", 0x3DC000u, 0x004000u, PARTITION_TYPE_LOCKED, {0}},
    {"nvram", 0x3E0000u, 0x004000u, PARTITION_TYPE_LOCKED, {0}},
    {"hib-backup", 0x3E4000u, 0x018000u, PARTITION_TYPE_LOCKED, {0}},
    {"plat-config", 0x3FC000u, 0x001000u, PARTITION_TYPE_LOCKED, {0}},
    {"reset-info", 0x3FD000u, 0x001000u, PARTITION_TYPE_LOCKED, {0}},
    {"excep-info", 0x3FE000u, 0x001000u, PARTITION_TYPE_LOCKED, {0}},
    {"reserved-tail", 0x3FF000u, 0x001000u, PARTITION_TYPE_LOCKED, {0}},
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

// Recompute a record CRC after deliberately changing its table. These
// regressions exercise semantics, independently of torn-write CRC detection.
static void repair_crc(uint8_t* record) {
  uint32_t len = 16 + (record[10] + record[11]) * sizeof(partition_entry);
  uint32_t crc = 0xffffffffu;
  for (uint32_t i = 0; i < len; i++) {
    crc ^= record[i];
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320u : 0);
    }
  }
  crc = ~crc;
  memcpy(record + len, &crc, sizeof(crc));
}

static void check_invalid_table(const partition_entry* bad, const char* name) {
  printf("invalid table: %s\n", name);
  erase_all();
  CHECK(anchor_write_table('A', 0, SLOT_STATE_NONE, test_table, TEST_TABLE_COUNT),
        "establish valid record");
  uint8_t before[2 * SECTOR];
  memcpy(before, __toit_anchor_start, sizeof(before));
  unsigned erases = g_erases;
  unsigned writes = g_writes;
  CHECK(!anchor_write_table('A', 0, SLOT_STATE_NONE, bad, TEST_TABLE_COUNT),
        "provisioning rejects malformed table");
  CHECK(!anchor_stage_table('A', 'B', bad, TEST_TABLE_COUNT, 1),
        "staging rejects malformed table");
  CHECK(g_erases == erases && g_writes == writes &&
            memcmp(before, __toit_anchor_start, sizeof(before)) == 0,
        "rejection does not erase or write flash");

  // Inject malformed active and pending tables into a newer, CRC-valid
  // record. Do not silently boot the older record's stale configuration.
  for (int trial = 0; trial < 2; trial++) {
    memcpy(__toit_anchor_start, before, sizeof(before));
    CHECK(anchor_stage('A', 'B'), "establish valid trial");
    uint8_t* record = __toit_anchor_start + SECTOR;
    size_t at = 16 + (trial ? sizeof(test_table) : 0);
    memcpy(record + at, bad, sizeof(test_table));
    repair_crc(record);
    slot_record r;
    partition_entry table[ANCHOR_MAX_ENTRIES];
    CHECK(!anchor_read(&r), "CRC-valid malformed table cannot select a boot record");
    CHECK(anchor_table_for_slot('A', table, ANCHOR_MAX_ENTRIES) == 0 &&
              anchor_table_for_slot('B', table, ANCHOR_MAX_ENTRIES) == 0,
          "neither configuration is exposed");
    erases = g_erases;
    writes = g_writes;
    CHECK(!anchor_rollback() && !anchor_validate('B') && !anchor_stage('A', 'B'),
          "transitions reject malformed source configuration");
    CHECK(g_erases == erases && g_writes == writes,
          "invalid source does not cause flash writes");
  }
}

static void test_table_validation(void) {
  const char* names[] = {
      "unknown type", "empty name", "unterminated name", "name padding",
      "invalid UTF-8", "duplicate name", "zero size", "unaligned size",
      "overlap", "flash overflow", "missing base", "wrong base name",
      "wrong base-id size", "wrong anchor size", "relocated anchor",
      "changed frozen base", "third slot", "unequal slots", "missing registry",
      "wrong registry type", "registry before slots", "missing base-id",
      "missing anchor", "missing slot", "incomplete coverage", "unaligned offset",
      "overlong UTF-8", "UTF-8 surrogate", "UTF-8 beyond Unicode", "truncated UTF-8",
  };
  for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
    partition_entry bad[TEST_TABLE_COUNT];
    memcpy(bad, test_table, sizeof(bad));
    if (i >= 26) memset(bad[0].name, 0, sizeof(bad[0].name));
    switch (i) {
      case 0: bad[0].type = 255; break;
      case 1: bad[0].name[0] = 0; break;
      case 2: memset(bad[0].name, 'x', sizeof(bad[0].name)); break;
      case 3: bad[0].name[15] = 'x'; break;
      case 4: bad[0].name[0] = (char)0xff; break;
      case 5: memcpy(bad[1].name, bad[0].name, 16); break;
      case 6: bad[0].size = 0; break;
      case 7: bad[0].size--; break;
      case 8: bad[1].offset -= SECTOR; break;
      case 9: bad[16].size = 0xfffff000u; break;
      case 10: bad[2].type = PARTITION_TYPE_LOCKED; break;
      case 11: bad[2].name[0] = 'x'; break;
      case 12:
        bad[3].size += SECTOR;
        bad[4].offset += SECTOR;
        bad[4].size -= SECTOR;
        break;
      case 13:
        bad[4].size += SECTOR;
        bad[5].offset += SECTOR;
        bad[5].size -= SECTOR;
        break;
      case 14:
        bad[4].size += 2 * SECTOR;
        bad[5].offset += 2 * SECTOR;
        bad[6].offset += 2 * SECTOR;
        bad[6].size -= SECTOR;
        bad[7].offset += SECTOR;
        bad[7].size -= SECTOR;
        break;
      case 15:
        bad[2].size += SECTOR;
        bad[3].offset += SECTOR;
        bad[4].offset += SECTOR;
        bad[4].size -= SECTOR;
        break;
      case 16: bad[8].type = PARTITION_TYPE_SLOT; break;
      case 17:
        bad[6].size -= SECTOR;
        bad[7].offset -= SECTOR;
        bad[7].size += SECTOR;
        break;
      case 18: bad[9].name[0] = 'x'; break;
      case 19: bad[9].type = PARTITION_TYPE_FREE; break;
      case 20:
        memcpy(bad[4].name, "registry", 9);
        bad[4].type = PARTITION_TYPE_DATA;
        memcpy(bad[9].name, "littlefs", 9);
        bad[9].type = PARTITION_TYPE_LOCKED;
        break;
      case 21: bad[3].type = PARTITION_TYPE_LOCKED; break;
      case 22: bad[5].type = PARTITION_TYPE_LOCKED; break;
      case 23: bad[7].type = PARTITION_TYPE_FREE; break;
      case 24: bad[16].size = 0; break;
      case 25: bad[0].offset = 1; break;
      case 26: memcpy(bad[0].name, "\xc0\xaf", 3); break;
      case 27: memcpy(bad[0].name, "\xed\xa0\x80", 4); break;
      case 28: memcpy(bad[0].name, "\xf4\x90\x80\x80", 5); break;
      case 29: memcpy(bad[0].name, "\xe2\x82", 3); break;
    }
    check_invalid_table(bad, names[i]);
  }
  erase_all();
  unsigned erases = g_erases;
  CHECK(!anchor_write_table('A', 0, SLOT_STATE_NONE, NULL, 0),
        "empty table rejected");
  CHECK(!anchor_write_table('A', 0, SLOT_STATE_NONE, test_table, -1),
        "negative count rejected");
  CHECK(!anchor_write_table('A', 0, SLOT_STATE_NONE, NULL, TEST_TABLE_COUNT),
        "null table rejected");
  CHECK(g_erases == erases, "invalid counts do not erase flash");
}

static void test_validation_boundaries(void) {
  partition_entry names[TEST_TABLE_COUNT];
  memcpy(names, test_table, sizeof(names));
  memset(names[0].name, 0, 16);
  memcpy(names[0].name, "\xc2\xa2\xe2\x82\xac\xf0\x9f\x98\x80", 9);
  erase_all();
  CHECK(anchor_write_table('A', 0, SLOT_STATE_NONE, names, TEST_TABLE_COUNT),
        "valid two/three/four-byte UTF-8 name accepted");
  memcpy(names[0].name, "123456789012345", 16);
  CHECK(anchor_write_table('A', 0, SLOT_STATE_NONE, names, TEST_TABLE_COUNT),
        "15-byte name accepted");

  // Split the registry's final 15 sectors into independent free entries.
  partition_entry full[ANCHOR_MAX_ENTRIES];
  memcpy(full, test_table, 10 * sizeof(partition_entry));
  full[9].size -= 15 * SECTOR;
  for (int i = 0; i < 15; i++) {
    partition_entry* p = &full[10 + i];
    memset(p, 0, sizeof(*p));
    memcpy(p->name, "extra-0", 8);
    p->name[6] = "0123456789abcde"[i];
    p->offset = full[9].offset + full[9].size + i * SECTOR;
    p->size = SECTOR;
    p->type = PARTITION_TYPE_FREE;
  }
  memcpy(full + 25, test_table + 10, 7 * sizeof(partition_entry));
  erase_all();
  CHECK(anchor_write_table('A', 0, SLOT_STATE_NONE, full, ANCHOR_MAX_ENTRIES),
        "maximum-size valid table accepted");
  CHECK(anchor_stage('A', 'B'), "two maximum-size tables fit a trial record");
  partition_entry out[ANCHOR_MAX_ENTRIES];
  CHECK(anchor_table_for_slot('B', out, ANCHOR_MAX_ENTRIES) == ANCHOR_MAX_ENTRIES &&
            tables_equal(full, out, ANCHOR_MAX_ENTRIES),
        "maximum trial table roundtrips");

  // Sequence exhaustion must fail before erasing: seq0 cannot supersede max.
  uint8_t* record = __toit_anchor_start + SECTOR;
  uint32_t sequence = UINT32_MAX;
  memcpy(record + 4, &sequence, sizeof(sequence));
  repair_crc(record);
  slot_record r;
  CHECK(anchor_read(&r) && r.seq == UINT32_MAX, "maximum sequence is readable");
  unsigned erases = g_erases;
  unsigned writes = g_writes;
  CHECK(!anchor_consume_trial('A', 'B') && !anchor_rollback(),
        "sequence exhaustion rejects transitions");
  CHECK(g_erases == erases && g_writes == writes,
        "sequence exhaustion leaves flash untouched");

  // Match native/header fallback semantics for a malformed zero active count.
  erase_all();
  CHECK(anchor_write_table('A', 0, SLOT_STATE_NONE, test_table, TEST_TABLE_COUNT),
        "establish fallback record");
  CHECK(anchor_stage('A', 'B'), "establish fallback trial");
  record = __toit_anchor_start + SECTOR;
  record[10] = 0;
  repair_crc(record);
  CHECK(anchor_read(&r) && r.seq == 1 && r.pending == 0,
        "invalid zero-count header falls back to valid partner");
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
  moved[6] = test_table[8];  // Move the free sector in front of slot A.
  moved[6].offset = test_table[6].offset;
  moved[7] = test_table[6];
  moved[7].offset += SECTOR;
  moved[8] = test_table[7];
  moved[8].offset += SECTOR;
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

  test_table_validation();
  test_validation_boundaries();

  printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "PASSED", g_failures,
         g_failures == 1 ? "" : "s");
  return g_failures ? 1 : 0;
}
