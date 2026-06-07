// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Unit tests for the EC618 dual-slot relocation core (src/slot_reloc_ec618.*),
// the engine behind the relocate-on-write / un-relocate-on-read OTA. Covers:
//   - the "SRL1" table parse + the ABS32 / Thumb-branch transforms;
//   - identity after relocation (relocate then un-relocate is a no-op);
//   - a patch site straddling a window boundary is rejected;
//   - the self-locating tail trailer round-trips;
//   - SlotFirmware presents the CANONICAL image (table-first, un-relocated) and
//     two slots that differ only by relocation yield byte-identical canonical
//     images — including a 2-aligned Thumb-branch site that straddles a 4-byte
//     boundary (the case a fixed word window would miss).
//
// The slot_reloc_ec618 sources are pure (no VM/PLAT state) and are compiled into
// the host toit_core library, so this test just links against it.

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <vector>

#include "../../src/top.h"
#include "../../src/slot_reloc_ec618.h"

using namespace toit;

static int g_failures = 0;
#define CHECK(cond, msg) do { \
  if (cond) { printf("  ok: %s\n", msg); } \
  else { printf("  FAIL: %s\n", msg); g_failures++; } } while (0)

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

// Builds an "SRL1" blob from ascending ABS32 / branch offset lists. `data_size`
// is the verbatim VM .data init image that rides after the body (0 = none).
static std::vector<uint8_t> build_table(uint32_t link_base, uint32_t slot_size, uint32_t body_size,
                                        const std::vector<uint32_t>& abs32,
                                        const std::vector<uint32_t>& thmbl,
                                        uint32_t data_size = 0) {
  std::vector<uint8_t> t;
  t.push_back('S'); t.push_back('R'); t.push_back('L'); t.push_back('1');
  put_le32(&t, link_base); put_le32(&t, slot_size); put_le32(&t, body_size);
  put_le32(&t, abs32.size()); put_le32(&t, thmbl.size());
  put_le32(&t, data_size);
  uint32_t prev = 0;
  for (uint32_t o : abs32) { put_varint(&t, o - prev); prev = o; }
  prev = 0;
  for (uint32_t o : thmbl) { put_varint(&t, o - prev); prev = o; }
  return t;
}

static void test_relocate_identity() {
  const uint32_t LINK = 0x991000, SIZE = 0x60000, BODY = 0x100, DELTA = SIZE;
  // One ABS32 pointer into the slot at offset 0x10; one Thumb BL at 0x40.
  std::vector<uint8_t> table = build_table(LINK, SIZE, BODY, {0x10}, {0x40});
  SlotRelocTable t;
  CHECK(slot_reloc_parse(table.data(), table.size(), &t), "table parses");
  CHECK(t.link_base == LINK && t.slot_size == SIZE && t.body_size == BODY, "header fields");
  CHECK(t.abs32_count == 1 && t.thmbl_count == 1, "counts");

  uint8_t buf[BODY];
  memset(buf, 0, sizeof(buf));
  uint32_t ptr = LINK + 0x80;  // ABS32 word points inside the slot.
  buf[0x10] = ptr; buf[0x11] = ptr >> 8; buf[0x12] = ptr >> 16; buf[0x13] = ptr >> 24;
  // A real Thumb-2 BL (f7 ff fc d2); its absolute value is irrelevant — we only
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

static void test_trailer() {
  // Build an SRL1 blob, lay it down as a tail trailer in a slot buffer, and
  // recover it from the slot's last word.
  std::vector<uint8_t> blob = build_table(0x991000, 0x60000, 0x100, {0x10, 0x20}, {0x40});
  const uint32_t SLOT = 0x10000;
  std::vector<uint8_t> slot(SLOT, 0xff);  // Erased flash.
  uint32_t region = ((blob.size() + 4) + 15) & ~15u;  // 16-align the block.
  CHECK(slot_reloc_build_trailer(blob.data(), blob.size(), slot.data() + SLOT - region, region),
        "build trailer");
  uint32_t last = slot[SLOT - 4] | (slot[SLOT - 3] << 8) | (slot[SLOT - 2] << 16) |
                  ((uint32_t)slot[SLOT - 1] << 24);
  CHECK(last == blob.size(), "last word == table size");
  SlotRelocTable t;
  CHECK(slot_reloc_parse_trailer(slot.data(), SLOT, &t), "parse trailer from tail");
  CHECK(t.abs32_count == 2 && t.thmbl_count == 1, "trailer table counts");
  std::vector<uint8_t> erased(SLOT, 0xff);
  CHECK(!slot_reloc_parse_trailer(erased.data(), SLOT, &t), "erased tail -> no table");
}

static void test_slot_firmware() {
  const uint32_t LINK = 0x991000, SIZE = 0x60000, BODY = 0x80, SLOT = 0x2000;
  std::vector<uint8_t> blob = build_table(LINK, SIZE, BODY, {0x10}, {0x42});
  while (blob.size() & 3) blob.push_back(0);  // Pad so the canonical body aligns.

  // Physical slot A (link base): an ABS32 pointer at 0x10, a Thumb BL at the
  // 2-aligned 0x42 (spans [0x42, 0x46), straddling the 0x44 boundary).
  std::vector<uint8_t> a(SLOT, 0xff);
  memset(a.data(), 0, BODY);
  uint32_t ptr = LINK + 0x40;
  a[0x10] = ptr; a[0x11] = ptr >> 8; a[0x12] = ptr >> 16; a[0x13] = ptr >> 24;
  a[0x42] = 0xf7; a[0x43] = 0xff; a[0x44] = 0xfc; a[0x45] = 0xd2;
  uint32_t region = blob.size() + 4;
  memcpy(a.data() + SLOT - region, blob.data(), blob.size());
  a[SLOT-4] = blob.size(); a[SLOT-3] = blob.size() >> 8;
  a[SLOT-2] = blob.size() >> 16; a[SLOT-1] = blob.size() >> 24;

  // Physical slot B: slot A relocated by +SIZE (the tail trailer is unchanged).
  std::vector<uint8_t> b = a;
  SlotRelocTable t; slot_reloc_parse(blob.data(), blob.size(), &t);
  slot_reloc_apply(&t, b.data(), 0, BODY, SIZE, SLOT_RELOC_TO_SLOT);

  SlotFirmware fa, fb;
  CHECK(fa.open(a.data(), LINK, SLOT), "slotfw open A");
  CHECK(fb.open(b.data(), LINK + SIZE, SLOT), "slotfw open B");
  CHECK(fa.canonical_size() == fb.canonical_size(), "slotfw canonical size A == B");
  uint32_t n = fa.canonical_size();
  CHECK(n == 4 + blob.size() + BODY, "slotfw canonical size value");

  int diff = 0;
  for (uint32_t i = 0; i < n; i++) if (fa.at(i) != fb.at(i)) diff++;
  CHECK(diff == 0, "slotfw canonical A == B (incl. straddling branch)");

  uint32_t bo = 4 + blob.size();
  int bad_body = 0;
  for (uint32_t k = 0; k < BODY; k++) if (fa.at(bo + k) != a[k]) bad_body++;
  CHECK(bad_body == 0, "slotfw slot-A canonical body == physical");

  std::vector<uint8_t> blk(BODY);
  CHECK(fb.copy(bo, bo + BODY, blk.data()), "slotfw copy body block");
  int bad_copy = 0;
  for (uint32_t k = 0; k < BODY; k++) if (blk[k] != fb.at(bo + k)) bad_copy++;
  CHECK(bad_copy == 0, "slotfw copy == at over body");

  // A block boundary that splits the straddling branch must still reassemble.
  std::vector<uint8_t> lo(8), hi(8);
  uint32_t split = bo + 0x44;  // 4-aligned boundary inside the BL at [0x42,0x46).
  bool ok = fb.copy(split - 8, split, lo.data()) && fb.copy(split, split + 8, hi.data());
  int bad_split = 0;
  for (uint32_t i = 0; i < 8; i++) {
    if (lo[i] != fb.at(split - 8 + i)) bad_split++;
    if (hi[i] != fb.at(split + i)) bad_split++;
  }
  CHECK(ok && bad_split == 0, "slotfw split-boundary copy reassembles branch");

  std::vector<uint8_t> erased(SLOT, 0xff);
  SlotFirmware bad;
  CHECK(!bad.open(erased.data(), LINK, SLOT), "slotfw rejects erased tail");
}

// The VM .data init image rides verbatim after the body: it is NOT relocated
// (even a word that looks like an in-slot pointer), so it reads back identically
// in slot A and slot B, and canonical_size accounts for it.
static void test_slot_firmware_data() {
  const uint32_t LINK = 0x991000, SIZE = 0x60000, BODY = 0x40, DATA = 0x20, SLOT = 0x2000;
  std::vector<uint8_t> blob = build_table(LINK, SIZE, BODY, {0x10}, {}, DATA);
  while (blob.size() & 3) blob.push_back(0);

  // Physical slot A: [ body (BODY) ][ .data (DATA) ][ free ][ table ][ size ].
  std::vector<uint8_t> a(SLOT, 0xff);
  memset(a.data(), 0, BODY + DATA);
  uint32_t ptr = LINK + 0x30;  // ABS32 in the body -> relocated.
  a[0x10] = ptr; a[0x11] = ptr >> 8; a[0x12] = ptr >> 16; a[0x13] = ptr >> 24;
  // A word in the .data region that LOOKS like an in-slot pointer; it must stay
  // verbatim (the body reloc table has no entry there, so it is never touched).
  uint32_t data_ptr = LINK + 0x10;
  a[BODY + 0] = data_ptr; a[BODY + 1] = data_ptr >> 8;
  a[BODY + 2] = data_ptr >> 16; a[BODY + 3] = data_ptr >> 24;
  uint32_t region = blob.size() + 4;
  memcpy(a.data() + SLOT - region, blob.data(), blob.size());
  a[SLOT-4] = blob.size(); a[SLOT-3] = blob.size() >> 8;
  a[SLOT-2] = blob.size() >> 16; a[SLOT-1] = blob.size() >> 24;

  // Physical slot B: relocate ONLY the body window; the .data stays as-is.
  std::vector<uint8_t> b = a;
  SlotRelocTable t; slot_reloc_parse(blob.data(), blob.size(), &t);
  slot_reloc_apply(&t, b.data(), 0, BODY, SIZE, SLOT_RELOC_TO_SLOT);

  SlotFirmware fa, fb;
  CHECK(fa.open(a.data(), LINK, SLOT), "slotfw+data open A");
  CHECK(fb.open(b.data(), LINK + SIZE, SLOT), "slotfw+data open B");
  CHECK(fa.canonical_size() == 4 + blob.size() + BODY + DATA, "canonical size includes data_size");

  uint32_t n = fa.canonical_size();
  int diff = 0;
  for (uint32_t i = 0; i < n; i++) if (fa.at(i) != fb.at(i)) diff++;
  CHECK(diff == 0, "canonical A == B across body + verbatim .data");

  // The .data bytes read back verbatim (NOT shifted by the slot delta).
  uint32_t data_off = 4 + blob.size() + BODY;
  uint32_t got = fa.at(data_off) | (fa.at(data_off+1) << 8) |
                 (fa.at(data_off+2) << 16) | ((uint32_t)fa.at(data_off+3) << 24);
  CHECK(got == data_ptr, "at(): .data pointer-looking word is verbatim (un-relocated)");
  std::vector<uint8_t> blk(DATA);
  CHECK(fb.copy(data_off, data_off + DATA, blk.data()), "copy() spans the .data region");
  uint32_t cgot = blk[0] | (blk[1] << 8) | (blk[2] << 16) | ((uint32_t)blk[3] << 24);
  CHECK(cgot == data_ptr, "copy(): .data is verbatim in slot B too");
}

int main(int, char**) {
  // The VM library this links against guards the global `new`; allow the
  // std::vector allocations this test uses (matches the other ctests).
  throwing_new_allowed = true;
  printf("relocate / un-relocate identity\n");
  test_relocate_identity();
  printf("window straddle rejection\n");
  test_straddle();
  printf("self-locating tail trailer\n");
  test_trailer();
  printf("SlotFirmware canonical read (table-first, un-relocated)\n");
  test_slot_firmware();
  printf("SlotFirmware verbatim VM .data region\n");
  test_slot_firmware_data();
  printf("\n%s (%d failure%s)\n", g_failures ? "FAILED" : "PASSED",
         g_failures, g_failures == 1 ? "" : "s");
  return g_failures ? 1 : 0;
}
