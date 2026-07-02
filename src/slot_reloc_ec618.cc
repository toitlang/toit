// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// Pure (no VM/PLAT dependencies) so it builds on the host for
// tools/slot_reloc_test/. See slot_reloc_ec618.h for the model.

#include "slot_reloc_ec618.h"

#include <string.h>

namespace toit {

static const uint8_t SRL2_MAGIC[4] = {'S', 'R', 'L', '2'};
static const size_t SRL2_HEADER_SIZE = 32;  // magic + 7 little-endian uint32s.

static uint32_t load_le32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) |
         (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

static void store_le32(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>(v);
  p[1] = static_cast<uint8_t>(v >> 8);
  p[2] = static_cast<uint8_t>(v >> 16);
  p[3] = static_cast<uint8_t>(v >> 24);
}

// Decodes one unsigned LEB128 varint at `p` (< `end`). Returns the byte after
// the varint, or nullptr on truncation.
static const uint8_t* decode_varint(const uint8_t* p, const uint8_t* end, uint32_t* out) {
  uint32_t value = 0;
  int shift = 0;
  while (p < end) {
    uint8_t b = *p++;
    value |= static_cast<uint32_t>(b & 0x7f) << shift;
    if ((b & 0x80) == 0) {
      *out = value;
      return p;
    }
    shift += 7;
  }
  return nullptr;
}

// Decodes the signed branch immediate of a Thumb-2 BL/B.W at `p` (4 bytes, two
// little-endian halfwords). The immediate is PC-relative to the instruction
// address + 4.
static int32_t thumb_branch_decode(const uint8_t* p) {
  uint32_t lo = static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8);
  uint32_t hi = static_cast<uint32_t>(p[2]) | (static_cast<uint32_t>(p[3]) << 8);
  uint32_t s = (lo >> 10) & 1;
  uint32_t imm10 = lo & 0x3ff;
  uint32_t j1 = (hi >> 13) & 1;
  uint32_t j2 = (hi >> 11) & 1;
  uint32_t imm11 = hi & 0x7ff;
  uint32_t i1 = (j1 ^ s) ^ 1;  // NOT(J1 XOR S).
  uint32_t i2 = (j2 ^ s) ^ 1;  // NOT(J2 XOR S).
  uint32_t imm = (s << 24) | (i1 << 23) | (i2 << 22) | (imm10 << 12) | (imm11 << 1);
  int32_t result = static_cast<int32_t>(imm);
  if (imm & 0x01000000) result -= 0x02000000;  // Sign-extend the 25-bit value.
  return result;
}

// Re-encodes the Thumb-2 BL/B.W at `p` with signed branch immediate `imm`,
// preserving the opcode bits (BL vs B.W).
static void thumb_branch_encode(uint8_t* p, int32_t imm) {
  uint32_t u = static_cast<uint32_t>(imm) & 0x01ffffff;
  uint32_t s = (u >> 24) & 1;
  uint32_t i1 = (u >> 23) & 1;
  uint32_t i2 = (u >> 22) & 1;
  uint32_t imm10 = (u >> 12) & 0x3ff;
  uint32_t imm11 = (u >> 1) & 0x7ff;
  uint32_t j1 = (i1 ^ 1) ^ s;  // NOT(I1) XOR S.
  uint32_t j2 = (i2 ^ 1) ^ s;  // NOT(I2) XOR S.
  uint32_t lo_old = static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8);
  uint32_t hi_old = static_cast<uint32_t>(p[2]) | (static_cast<uint32_t>(p[3]) << 8);
  uint32_t lo = (lo_old & 0xf800) | (s << 10) | imm10;
  uint32_t hi = (hi_old & 0xd000) | (j1 << 13) | (j2 << 11) | imm11;
  p[0] = static_cast<uint8_t>(lo);
  p[1] = static_cast<uint8_t>(lo >> 8);
  p[2] = static_cast<uint8_t>(hi);
  p[3] = static_cast<uint8_t>(hi >> 8);
}

bool slot_reloc_parse(const uint8_t* blob, size_t len, SlotRelocTable* table) {
  if (len < SRL2_HEADER_SIZE) return false;
  for (int i = 0; i < 4; i++) {
    if (blob[i] != SRL2_MAGIC[i]) return false;
  }
  table->link_base = load_le32(blob + 4);
  table->slot_size = load_le32(blob + 8);
  table->body_size = load_le32(blob + 12);
  table->abs32_count = load_le32(blob + 16);
  table->thmbl_count = load_le32(blob + 20);
  table->data_size = load_le32(blob + 24);
  table->straddle_count = load_le32(blob + 28);
  table->end = blob + len;
  const uint8_t* p = blob + SRL2_HEADER_SIZE;
  table->abs32_varints = p;
  // Walk the ABS32 stream to locate the start of the branch stream.
  for (uint32_t i = 0; i < table->abs32_count; i++) {
    uint32_t delta;
    p = decode_varint(p, table->end, &delta);
    if (p == nullptr) return false;
  }
  table->thmbl_varints = p;
  // Walk the branch stream to locate the start of the straddle stream.
  for (uint32_t i = 0; i < table->thmbl_count; i++) {
    uint32_t delta;
    p = decode_varint(p, table->end, &delta);
    if (p == nullptr) return false;
  }
  table->straddle_entries = p;
  // Validate the straddle stream (delta-varint offset + 4 canonical site
  // bytes per entry) is well-formed and fully contained.
  for (uint32_t i = 0; i < table->straddle_count; i++) {
    uint32_t delta;
    p = decode_varint(p, table->end, &delta);
    if (p == nullptr || p + 4 > table->end) return false;
    p += 4;
  }
  return true;
}

bool slot_reloc_parse_trailer(const uint8_t* slot, uint32_t slot_size, SlotRelocTable* table) {
  if (slot_size < SRL2_HEADER_SIZE + 4) return false;
  uint32_t n = load_le32(slot + slot_size - 4);
  // An erased tail reads as 0xffffffff; reject that and any implausible size.
  if (n < SRL2_HEADER_SIZE || n > slot_size - 4) return false;
  return slot_reloc_parse(slot + slot_size - 4 - n, n, table);
}

bool slot_reloc_build_trailer(const uint8_t* table_blob, uint32_t len,
                              uint8_t* out, uint32_t out_size) {
  if (out_size < len + 4) return false;
  uint32_t pad = out_size - len - 4;
  for (uint32_t i = 0; i < pad; i++) out[i] = 0xff;  // Leave the lead as erased.
  for (uint32_t i = 0; i < len; i++) out[pad + i] = table_blob[i];
  store_le32(out + pad + len, len);                  // Size in the last word.
  return true;
}

// Applies one delta-encoded offset stream to the window. `word_delta` is added
// to ABS32 words / branch immediates as appropriate. Returns false if a patch
// site straddles the window boundary.
static bool apply_stream(const uint8_t* p, const uint8_t* end, uint32_t count,
                         uint8_t* buf, uint32_t window_off, uint32_t window_end,
                         int32_t word_delta, bool is_branch) {
  uint32_t off = 0;
  for (uint32_t i = 0; i < count; i++) {
    uint32_t step;
    p = decode_varint(p, end, &step);
    if (p == nullptr) return false;
    off += step;
    if (off >= window_end) break;            // Ascending: nothing more here.
    if (off + 4 <= window_off) continue;     // Fully before the window.
    if (off < window_off || off + 4 > window_end) return false;  // Straddles.
    uint8_t* q = buf + (off - window_off);
    if (is_branch) {
      thumb_branch_encode(q, thumb_branch_decode(q) + word_delta);
    } else {
      store_le32(q, load_le32(q) + static_cast<uint32_t>(word_delta));
    }
  }
  return true;
}

// Applies the straddle stream to the window: entries carry the site's 4
// CANONICAL bytes, so the full target site is computed chunk-locally — for
// TO_SLOT the canonical immediate is re-encoded with `branch_delta`, for
// TO_CANONICAL the canonical bytes ARE the target — and whichever part of the
// site overlaps [window_off, window_end) is written. Stateless for any window
// split, including a site split across two windows.
static bool apply_straddles(const SlotRelocTable* table,
                            uint8_t* buf, uint32_t window_off, uint32_t window_end,
                            int32_t branch_delta, SlotRelocDir dir) {
  const uint8_t* p = table->straddle_entries;
  uint32_t off = 0;
  for (uint32_t i = 0; i < table->straddle_count; i++) {
    uint32_t step;
    p = decode_varint(p, table->end, &step);
    if (p == nullptr || p + 4 > table->end) return false;
    const uint8_t* canonical = p;
    p += 4;
    off += step;
    if (off >= window_end) break;            // Ascending: nothing more here.
    if (off + 4 <= window_off) continue;     // Fully before the window.
    uint8_t site[4];
    memcpy(site, canonical, 4);
    if (dir == SLOT_RELOC_TO_SLOT) {
      thumb_branch_encode(site, thumb_branch_decode(site) + branch_delta);
    }
    uint32_t lo = off > window_off ? off : window_off;
    uint32_t hi = (off + 4) < window_end ? (off + 4) : window_end;
    for (uint32_t k = lo; k < hi; k++) buf[k - window_off] = site[k - off];
  }
  return true;
}

bool slot_reloc_apply(const SlotRelocTable* table,
                      uint8_t* buf, uint32_t window_off, uint32_t window_len,
                      int32_t delta, SlotRelocDir dir) {
  if (delta == 0) return true;  // Image already at the link base: nothing to do.
  // ABS32 pointers move WITH the slot; branches to fixed targets move AGAINST
  // it (their source moved, target did not), hence the opposite sign.
  int32_t word_delta = (dir == SLOT_RELOC_TO_SLOT) ? delta : -delta;
  int32_t branch_delta = -word_delta;
  uint32_t window_end = window_off + window_len;
  if (!apply_stream(table->abs32_varints, table->thmbl_varints, table->abs32_count,
                    buf, window_off, window_end, word_delta, /*is_branch=*/false)) {
    return false;
  }
  if (!apply_stream(table->thmbl_varints, table->straddle_entries, table->thmbl_count,
                    buf, window_off, window_end, branch_delta, /*is_branch=*/true)) {
    return false;
  }
  return apply_straddles(table, buf, window_off, window_end, branch_delta, dir);
}

bool SlotFirmware::open(const uint8_t* slot, uint32_t slot_base_addr, uint32_t slot_size) {
  valid_ = false;
  if (slot_size < SRL2_HEADER_SIZE + 4) return false;
  uint32_t n = load_le32(slot + slot_size - 4);
  // An erased tail reads as 0xffffffff; reject that and any implausible size.
  if (n < SRL2_HEADER_SIZE || n > slot_size - 4) return false;
  // The builder pads the table to a word so the canonical body (at 4 + N)
  // starts on a 4-byte boundary — required for word-granular un-relocation.
  if ((n & 3) != 0) return false;
  const uint8_t* blob = slot + slot_size - 4 - n;
  if (!slot_reloc_parse(blob, n, &table_)) return false;
  slot_ = slot;
  slot_size_ = slot_size;
  table_blob_ = blob;
  table_len_ = n;
  populated_ = table_.body_size;
  delta_ = static_cast<int32_t>(slot_base_addr) - static_cast<int32_t>(table_.link_base);
  // The verbatim VM .data init image rides physically right after the body
  // (slot offset `populated_`, length `data_size`) and canonically right after
  // the body region. It carries no reloc sites, so the body-window machinery in
  // copy()/at() streams it through untouched — only canonical_size_ grows.
  canonical_size_ = 4 + table_len_ + populated_ + table_.data_size;
  valid_ = true;
  return true;
}

void SlotFirmware::unrelocate_window(uint8_t* buf, uint32_t wf, uint32_t wt) const {
  if (delta_ == 0) return;  // Slot already at the link base: canonical as-is.
  // ABS32 words move WITH the slot, so un-relocating subtracts the slot delta;
  // branches to a fixed target move AGAINST it, so theirs adds it.
  uint32_t word_delta = static_cast<uint32_t>(-delta_);
  int32_t branch_delta = delta_;

  // ABS32 sites: 4-byte words at 4-aligned offsets, fully contained in [wf, wt)
  // because both bounds are word-aligned. Modify in place in `buf`.
  const uint8_t* p = table_.abs32_varints;
  uint32_t off = 0;
  for (uint32_t i = 0; i < table_.abs32_count; i++) {
    uint32_t step;
    p = decode_varint(p, table_.thmbl_varints, &step);
    if (p == nullptr) return;
    off += step;
    if (off >= wt) break;            // Ascending: nothing more in the window.
    if (off < wf) continue;
    uint8_t* q = buf + (off - wf);
    store_le32(q, load_le32(q) + word_delta);
  }

  // Thumb-branch sites: 4 bytes at 2-aligned offsets, so they can straddle the
  // window bounds. Re-encode each from the FULL site in the slot and copy only
  // the bytes that fall inside [wf, wt).
  p = table_.thmbl_varints;
  off = 0;
  for (uint32_t i = 0; i < table_.thmbl_count; i++) {
    uint32_t step;
    p = decode_varint(p, table_.straddle_entries, &step);
    if (p == nullptr) return;
    off += step;
    if (off >= wt) break;            // Site starts at/after the window end.
    if (off + 4 <= wf) continue;     // Site ends at/before the window start.
    uint8_t site[4];
    memcpy(site, slot_ + off, 4);
    thumb_branch_encode(site, thumb_branch_decode(site) + branch_delta);
    uint32_t lo = off > wf ? off : wf;
    uint32_t hi = (off + 4) < wt ? (off + 4) : wt;
    for (uint32_t k = lo; k < hi; k++) buf[k - wf] = site[k - off];
  }

  // Sector-straddling branch sites: their entries carry the site's canonical
  // bytes, so un-relocation is a verbatim copy of the in-window overlap.
  p = table_.straddle_entries;
  off = 0;
  for (uint32_t i = 0; i < table_.straddle_count; i++) {
    uint32_t step;
    p = decode_varint(p, table_.end, &step);
    if (p == nullptr || p + 4 > table_.end) return;
    const uint8_t* canonical = p;
    p += 4;
    off += step;
    if (off >= wt) break;            // Site starts at/after the window end.
    if (off + 4 <= wf) continue;     // Site ends at/before the window start.
    uint32_t lo = off > wf ? off : wf;
    uint32_t hi = (off + 4) < wt ? (off + 4) : wt;
    for (uint32_t k = lo; k < hi; k++) buf[k - wf] = canonical[k - off];
  }
}

uint8_t SlotFirmware::at(uint32_t index) const {
  if (index < 4) {
    return static_cast<uint8_t>(table_len_ >> (index * 8));  // Size word (LE).
  }
  if (index < body_off()) {
    return table_blob_[index - 4];                           // Table bytes.
  }
  // Body: un-relocate the containing 4-byte window (which may also pick up a
  // straddling branch site from the neighbouring word) and extract the byte.
  uint32_t body = index - body_off();
  uint32_t word_off = body & ~static_cast<uint32_t>(3);
  uint8_t word[4];
  memcpy(word, slot_ + word_off, 4);
  unrelocate_window(word, word_off, word_off + 4);
  return word[body & 3];
}

bool SlotFirmware::copy(uint32_t from, uint32_t to, uint8_t* dest) const {
  if (from > to || to > canonical_size_) return false;
  uint32_t pos = from;
  uint32_t d = 0;
  // Size-word region [0, 4): the little-endian table length.
  if (pos < 4) {
    uint32_t end = to < 4 ? to : 4;
    for (; pos < end; pos++) dest[d++] = static_cast<uint8_t>(table_len_ >> (pos * 8));
  }
  // Table region [4, body_off): the slot-independent reloc table bytes.
  if (pos < body_off() && pos < to) {
    uint32_t end = to < body_off() ? to : body_off();
    memcpy(dest + d, table_blob_ + (pos - 4), end - pos);
    d += end - pos;
    pos = end;
  }
  // Body region [body_off, canonical_size): physical body, un-relocated. The
  // window must be word-aligned (the block-copy caller guarantees this; single
  // bytes go through `at`); straddling branch sites are handled per byte.
  if (pos < to) {
    uint32_t body_from = pos - body_off();
    uint32_t body_to = to - body_off();
    if ((body_from & 3) != 0 || (body_to & 3) != 0) return false;
    memcpy(dest + d, slot_ + body_from, body_to - body_from);
    unrelocate_window(dest + d, body_from, body_to);
  }
  return true;
}

}  // namespace toit
