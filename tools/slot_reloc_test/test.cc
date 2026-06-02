// Copyright (C) 2026 Toit contributors.
//
// Host unit test for src/slot_reloc_ec618.cc — the EC618 dual-slot relocation
// core. Proves:
//   - the "SRL1" table parses and the ABS32 / Thumb-branch transforms are
//     exact and invertible (relocate then un-relocate is the identity);
//   - a patch site straddling a window boundary is rejected;
//   - relocating in sector-sized windows matches a single whole-body window
//     (the device writes the slot one sector at a time).
//
// With three extra arguments — ap_a.bin ap_b.bin slot-reloc.bin (the build's
// build/ec618/ap-slot-{a,b}.bin and slot-reloc.bin) — it also runs the gold
// check against the independent slot-B link: relocate slot A == slot B, and
// un-relocate slot B == slot A, whole-body and sector-chunked.
//
// Build + run (synthetic only):
//   g++ -Wall -Wextra -O2 -I src tools/slot_reloc_test/test.cc
//       src/slot_reloc_ec618.cc -o /tmp/slot_reloc_test && /tmp/slot_reloc_test
// With real artifacts: append ap-slot-a.bin ap-slot-b.bin slot-reloc.bin.

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

// Appends `value` to `out` as an unsigned LEB128 varint.
static void put_varint(std::vector<uint8_t>* out, uint32_t value) {
  for (;;) {
    uint8_t b = value & 0x7f;
    value >>= 7;
    if (value != 0) { out->push_back(b | 0x80); }
    else { out->push_back(b); return; }
  }
}

static void put_le32(std::vector<uint8_t>* out, uint32_t v) {
  out->push_back(v); out->push_back(v >> 8); out->push_back(v >> 16); out->push_back(v >> 24);
}

// Builds an "SRL1" blob from ascending ABS32 / branch offset lists.
static std::vector<uint8_t> build_table(uint32_t link_base, uint32_t slot_size, uint32_t body_size,
                                        const std::vector<uint32_t>& abs32,
                                        const std::vector<uint32_t>& thmbl) {
  std::vector<uint8_t> t;
  t.push_back('S'); t.push_back('R'); t.push_back('L'); t.push_back('1');
  put_le32(&t, link_base); put_le32(&t, slot_size); put_le32(&t, body_size);
  put_le32(&t, abs32.size()); put_le32(&t, thmbl.size());
  uint32_t prev = 0;
  for (uint32_t o : abs32) { put_varint(&t, o - prev); prev = o; }
  prev = 0;
  for (uint32_t o : thmbl) { put_varint(&t, o - prev); prev = o; }
  return t;
}

static void test_synthetic() {
  const uint32_t LINK = 0x991000, SIZE = 0x60000, BODY = 0x100, DELTA = SIZE;
  // One ABS32 pointer into the slot at offset 0x10; one Thumb BL at 0x40.
  std::vector<uint8_t> table = build_table(LINK, SIZE, BODY, {0x10}, {0x40});
  SlotRelocTable t;
  CHECK(slot_reloc_parse(table.data(), table.size(), &t), "table parses");
  CHECK(t.link_base == LINK && t.slot_size == SIZE && t.body_size == BODY, "header fields");
  CHECK(t.abs32_count == 1 && t.thmbl_count == 1, "counts");

  uint8_t buf[BODY];
  memset(buf, 0, sizeof(buf));
  // ABS32 word points at LINK + 0x80 (inside the slot).
  uint32_t ptr = LINK + 0x80;
  buf[0x10] = ptr; buf[0x11] = ptr >> 8; buf[0x12] = ptr >> 16; buf[0x13] = ptr >> 24;
  // A real Thumb-2 BL: __wrap_time call from the live image (bytes f7 ff fc d2,
  // at 0x9b4e4a -> 0x86246c). Its absolute value is irrelevant here; we only
  // check the transform is exact and invertible.
  buf[0x40] = 0xf7; buf[0x41] = 0xff; buf[0x42] = 0xfc; buf[0x43] = 0xd2;
  uint8_t original[BODY];
  memcpy(original, buf, BODY);

  CHECK(slot_reloc_apply(&t, buf, 0, BODY, DELTA, SLOT_RELOC_TO_SLOT), "relocate ok");
  uint32_t got = buf[0x10] | (buf[0x11] << 8) | (buf[0x12] << 16) | ((uint32_t)buf[0x13] << 24);
  CHECK(got == ptr + DELTA, "ABS32 += delta");
  CHECK(memcmp(buf + 0x40, original + 0x40, 4) != 0, "BL changed");

  CHECK(slot_reloc_apply(&t, buf, 0, BODY, DELTA, SLOT_RELOC_TO_CANONICAL), "un-relocate ok");
  CHECK(memcmp(buf, original, BODY) == 0, "relocate then un-relocate is identity");

  // delta == 0 is a no-op.
  uint8_t z[BODY]; memcpy(z, original, BODY);
  CHECK(slot_reloc_apply(&t, z, 0, BODY, 0, SLOT_RELOC_TO_SLOT), "delta 0 ok");
  CHECK(memcmp(z, original, BODY) == 0, "delta 0 leaves bytes untouched");
}

static void test_straddle() {
  const uint32_t LINK = 0x991000, SIZE = 0x60000, BODY = 0x100;
  std::vector<uint8_t> table = build_table(LINK, SIZE, BODY, {0x20}, {});
  SlotRelocTable t;
  slot_reloc_parse(table.data(), table.size(), &t);
  uint8_t buf[BODY]; memset(buf, 0, sizeof(buf));
  // A window ending at 0x22 splits the 4-byte ABS32 at 0x20 -> must be rejected.
  CHECK(!slot_reloc_apply(&t, buf, 0x00, 0x22, SIZE, SLOT_RELOC_TO_SLOT), "straddle at window end rejected");
  // A window starting at 0x22 splits it from the other side.
  CHECK(!slot_reloc_apply(&t, buf + 0x22, 0x22, BODY - 0x22, SIZE, SLOT_RELOC_TO_SLOT), "straddle at window start rejected");
}

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

static void test_real(const char* ap_a_path, const char* ap_b_path, const char* table_path) {
  size_t a_len = 0, b_len = 0, t_len = 0;
  uint8_t* ap_a = read_file(ap_a_path, &a_len);
  uint8_t* ap_b = read_file(ap_b_path, &b_len);
  uint8_t* tbl = read_file(table_path, &t_len);
  CHECK(ap_a && ap_b && tbl, "read real artifacts");
  if (!(ap_a && ap_b && tbl)) return;

  SlotRelocTable t;
  CHECK(slot_reloc_parse(tbl, t_len, &t), "real table parses");

  uint32_t body = t.body_size;
  int32_t delta = static_cast<int32_t>(t.slot_size);  // Slot A -> slot B.
  uint32_t slot_a_file = t.link_base - AP_LOAD_ADDR;
  uint32_t slot_b_file = t.link_base + t.slot_size - AP_LOAD_ADDR;
  const uint8_t* slot_a = ap_a + slot_a_file;
  const uint8_t* slot_b = ap_b + slot_b_file;

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
  printf("synthetic relocate/un-relocate\n");
  test_synthetic();
  printf("window straddle rejection\n");
  test_straddle();
  if (argc >= 4) {
    printf("real artifacts (slot-B link cross-check)\n");
    test_real(argv[1], argv[2], argv[3]);
  } else {
    printf("(skipping real-artifact check; pass ap_a.bin ap_b.bin slot-reloc.bin to enable)\n");
  }
  printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "PASSED",
         g_failures, g_failures == 1 ? "" : "s");
  return g_failures ? 1 : 0;
}
