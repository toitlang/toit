// Copyright (C) 2026 Toit contributors.
//
// Host unit test for slot_marker.c. Backs the two-sector marker with a RAM
// buffer and a fault-injectable flash emulator, then asserts the
// power-fail-safe invariants:
//   - ping-pong picks the higher-seq valid record;
//   - a torn (partial) write fails CRC and the *other* sector is used;
//   - an erase-then-crash (target sector blank) falls back to the other;
//   - fresh/erased flash reads as "default slot A".
//
// Build + run (one line):
//   gcc -Wall -Wextra -O2 -I tools/slot_marker_test
//   -I toolchains/ec618/project/inc tools/slot_marker_test/test.c
//   toolchains/ec618/project/src/slot_marker.c
//   -o /tmp/slot_marker_test && /tmp/slot_marker_test

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "flash_rt.h"
#include "slot_marker.h"

#define SECTOR 0x1000u

// The "flash": two marker sectors. slot_marker.c reads it via XIP (a plain
// pointer) and writes it via the BSP emulator below.
uint8_t __slot_marker_start[2 * SECTOR];

// Consulted by slot_marker.c (normally provided by sys_ro_override.c).
uint32_t toit_ap_image_modify_start = 0;
uint32_t toit_ap_image_modify_end = 0;

// Fault injection: if >= 0, the next BSP_QSPI_Write_Safe writes only this
// many bytes then "loses power" (returns OK but leaves a torn record).
static int g_torn_write_bytes = -1;
// If non-zero, the next erase succeeds but the following write is skipped
// entirely (erase-then-crash).
static int g_skip_next_write = 0;

static uint32_t base_addr(void) { return (uint32_t)(uintptr_t)__slot_marker_start; }

uint8_t BSP_QSPI_Erase_Safe(uint32_t addr, uint32_t size) {
  uint32_t off = addr - base_addr();
  memset(__slot_marker_start + off, 0xff, size);
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
  memcpy(__slot_marker_start + off, data, n);
  return QSPI_OK;
}

static int g_failures = 0;
#define CHECK(cond, msg) do { \
  if (cond) { printf("  ok: %s\n", msg); } \
  else { printf("  FAIL: %s\n", msg); g_failures++; } } while (0)

static void erase_all(void) { memset(__slot_marker_start, 0xff, sizeof(__slot_marker_start)); }

int main(void) {
  slot_record r;

  printf("fresh flash -> default A\n");
  erase_all();
  CHECK(!slot_marker_read(&r), "no stored record");
  CHECK(r.active == 'A' && r.pending == 0, "defaults to active=A pending=0");

  printf("stage B as NEW\n");
  CHECK(slot_marker_write('A', 'B', SLOT_STATE_NEW), "write ok");
  CHECK(slot_marker_read(&r), "record found");
  CHECK(r.active == 'A' && r.pending == 'B' && r.state == SLOT_STATE_NEW, "A/B/NEW");
  CHECK(r.seq == 1, "seq == 1");

  printf("consume trial -> PENDING_VERIFY (ping-pong to other sector)\n");
  CHECK(slot_marker_write('A', 'B', SLOT_STATE_PENDING_VERIFY), "write ok");
  CHECK(slot_marker_read(&r), "record found");
  CHECK(r.state == SLOT_STATE_PENDING_VERIFY && r.seq == 2, "PENDING_VERIFY seq2");

  printf("validate -> active=B pending=0\n");
  CHECK(slot_marker_write('B', 0, SLOT_STATE_NONE), "write ok");
  CHECK(slot_marker_read(&r), "record found");
  CHECK(r.active == 'B' && r.pending == 0 && r.seq == 3, "B/none seq3");

  printf("torn write: partial record fails CRC, previous record survives\n");
  // Current valid record is seq3 (active B). A torn write of the next
  // record must leave the reader on seq3.
  g_torn_write_bytes = 8;  // Write only 8 of 16 bytes, then "lose power".
  slot_marker_write('A', 'B', SLOT_STATE_NEW);  // Targets the other sector.
  CHECK(slot_marker_read(&r), "a valid record still exists");
  CHECK(r.active == 'B' && r.seq == 3, "fell back to seq3 (torn write ignored)");

  printf("erase-then-crash: blank target sector, previous record survives\n");
  g_skip_next_write = 1;
  slot_marker_write('A', 'B', SLOT_STATE_NEW);
  CHECK(slot_marker_read(&r), "a valid record still exists");
  CHECK(r.active == 'B' && r.seq == 3, "fell back to seq3 (blank sector ignored)");

  printf("recovery: a real write after the failures succeeds and wins\n");
  CHECK(slot_marker_write('A', 'B', SLOT_STATE_NEW), "write ok");
  CHECK(slot_marker_read(&r), "record found");
  CHECK(r.active == 'A' && r.pending == 'B' && r.seq == 4, "A/B/NEW seq4");

  printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "PASSED",
         g_failures, g_failures == 1 ? "" : "s");
  return g_failures ? 1 : 0;
}
