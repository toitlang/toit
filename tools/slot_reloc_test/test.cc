// Copyright (C) 2026 Toit contributors.
//
// Build-integration GOLD CHECK for src/slot_reloc_ec618.cc — the EC618
// dual-slot relocation core (the C++ that runs on the chip). Given the actual
// build artifacts (build/ec618/ap-slot-{a,b}.bin and slot-reloc.bin), it proves
// the device relocator handles the REAL ~1900-entry table byte-identically
// against the independent slot-B link:
//   - relocate slot A == slot B link (whole-body and sector-chunked, the way
//     the device writes the slot);
//   - un-relocate slot B == slot A link (the read path).
//
// This complements the Toit-side byte-identity proof in gen-slot-reloc.toit
// (--verify-slot-b): that proves the table/model, this proves the C++ that
// consumes it. The self-contained UNIT tests for the relocation transforms,
// the tail trailer, and SlotFirmware live in
// tests/ctest/ec618-slot-reloc-test.cc.
//
// Build + run (from `make ec618`):
//   g++ -Wall -Wextra -O2 -I src tools/slot_reloc_test/test.cc
//       src/slot_reloc_ec618.cc -o slot_reloc_test
//   slot_reloc_test build/ec618/ap-slot-a.bin build/ec618/ap-slot-b.bin
//       build/ec618/slot-reloc.bin

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

#include "slot_reloc_ec618.h"

using namespace toit;

// XIP address of ap.bin byte 0 (AP_FLASH_LOAD_ADDR); maps a slot's link base
// to its file offset within ap.bin.
static const uint32_t AP_LOAD_ADDR = 0x824000;
static const uint32_t SECTOR = 0x1000;

static int g_failures = 0;
#define CHECK(cond, msg) do { \
  if (cond) { printf("  ok: %s\n", msg); } \
  else { printf("  FAIL: %s\n", msg); g_failures++; } } while (0)

static uint8_t* read_file(const char* path, size_t* len) {
  FILE* f = fopen(path, "rb");
  if (f == nullptr) return nullptr;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t* buf = static_cast<uint8_t*>(malloc(n));
  size_t got = fread(buf, 1, n, f);
  fclose(f);
  if (got != static_cast<size_t>(n)) { free(buf); return nullptr; }
  *len = n;
  return buf;
}

// Relocates `src` (the canonical/link-base slot region) into `dst` one sector
// at a time, exactly as the device writes the slot. Returns false if any
// window is rejected.
static bool relocate_chunked(const SlotRelocTable* t, const uint8_t* src, uint8_t* dst,
                             uint32_t body, int32_t delta, SlotRelocDir dir) {
  memcpy(dst, src, body);
  for (uint32_t off = 0; off < body; off += SECTOR) {
    uint32_t len = (body - off < SECTOR) ? body - off : SECTOR;
    if (!slot_reloc_apply(t, dst + off, off, len, delta, dir)) return false;
  }
  return true;
}

static void test_real(const char* ap_a_path, const char* ap_b_path, const char* table_path,
                      uint32_t slot_a_flash, uint32_t slot_b_flash) {
  size_t a_len = 0, b_len = 0, t_len = 0;
  uint8_t* ap_a = read_file(ap_a_path, &a_len);
  uint8_t* ap_b = read_file(ap_b_path, &b_len);
  uint8_t* tbl = read_file(table_path, &t_len);
  CHECK(ap_a && ap_b && tbl, "read real artifacts");
  if (!(ap_a && ap_b && tbl)) return;

  SlotRelocTable t;
  CHECK(slot_reloc_parse(tbl, t_len, &t), "real table parses");

  uint32_t body = t.body_size;
  // The image is LINKED at t.link_base (the neutral canonical base, NEITHER
  // slot). ap_a (the slot-A link) holds the canonical body at slot A's flash
  // file offset; ap_b (the slot-B link) is the oracle at slot B's address. The
  // device adds `dest_slot_base - link_base`, so the canonical-to-slot-B delta
  // is non-zero even though slot A also relocates now.
  int32_t delta = static_cast<int32_t>(slot_b_flash - t.link_base);
  uint32_t slot_a_file = slot_a_flash - AP_LOAD_ADDR;
  uint32_t slot_b_file = slot_b_flash - AP_LOAD_ADDR;
  const uint8_t* slot_a = ap_a + slot_a_file;  // The canonical (link-base) body.
  const uint8_t* slot_b = ap_b + slot_b_file;  // The slot-B oracle.

  std::vector<uint8_t> work(body);

  // Whole-body: relocate slot A -> slot B.
  memcpy(work.data(), slot_a, body);
  CHECK(slot_reloc_apply(&t, work.data(), 0, body, delta, SLOT_RELOC_TO_SLOT), "whole-body relocate ok");
  CHECK(memcmp(work.data(), slot_b, body) == 0, "relocated slot A == slot-B link (whole body)");

  // Whole-body: un-relocate slot B -> slot A (canonical).
  memcpy(work.data(), slot_b, body);
  CHECK(slot_reloc_apply(&t, work.data(), 0, body, delta, SLOT_RELOC_TO_CANONICAL), "whole-body un-relocate ok");
  CHECK(memcmp(work.data(), slot_a, body) == 0, "un-relocated slot B == slot-A link (whole body)");

  // Sector-chunked (the device write path): relocate slot A -> slot B.
  CHECK(relocate_chunked(&t, slot_a, work.data(), body, delta, SLOT_RELOC_TO_SLOT), "sector-chunked relocate ok");
  CHECK(memcmp(work.data(), slot_b, body) == 0, "sector-chunked relocate == slot-B link");

  // Sector-chunked: un-relocate slot B -> slot A.
  CHECK(relocate_chunked(&t, slot_b, work.data(), body, delta, SLOT_RELOC_TO_CANONICAL), "sector-chunked un-relocate ok");
  CHECK(memcmp(work.data(), slot_a, body) == 0, "sector-chunked un-relocate == slot-A link");

  free(ap_a); free(ap_b); free(tbl);
}

int main(int argc, char** argv) {
  if (argc < 6) {
    printf("usage: %s ap-slot-a.bin ap-slot-b.bin slot-reloc.bin slot-a-flash slot-b-flash\n", argv[0]);
    printf("  slot-a-flash/slot-b-flash: the slots' XIP flash addresses (hex, e.g. 0x991000 0xA51000)\n");
    printf("(the self-contained unit tests live in tests/ctest/ec618-slot-reloc-test.cc)\n");
    return 2;
  }
  uint32_t slot_a_flash = static_cast<uint32_t>(strtoul(argv[4], nullptr, 0));
  uint32_t slot_b_flash = static_cast<uint32_t>(strtoul(argv[5], nullptr, 0));
  printf("real artifacts (slot-B link cross-check)\n");
  test_real(argv[1], argv[2], argv[3], slot_a_flash, slot_b_flash);
  printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "PASSED",
         g_failures, g_failures == 1 ? "" : "s");
  return g_failures ? 1 : 0;
}
