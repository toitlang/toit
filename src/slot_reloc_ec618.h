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

// EC618 dual-slot relocation.
//
// The Toit firmware is one position-independent image, linked once at slot A's
// base. The handful of words that depend on the slot base are captured in a
// relocation table (the "SRL2" artifact, see tools/ec618/gen-slot-reloc.toit).
// This module applies that table, in BOTH directions, so the relocation is
// invisible to the (architecture-agnostic) Toit firmware code:
//
//   - relocate   (canonical link-base image -> a destination slot): used when
//     writing a new image to the inactive slot. `word += delta` for ABS32
//     pointers into the slot; `imm -= delta` for the Thumb branches that
//     escape the slot to a fixed address (the __wrap_time shim).
//   - un-relocate (a slot -> canonical link-base image): used when reading the
//     active slot back (firmware.map, SHA, delta-OTA), so every reader sees the
//     same canonical bytes regardless of which slot is live. The inverse:
//     `word -= delta`, `imm += delta`.
//
// `delta = dest_slot_base - link_base` (0 when the image already sits at the
// link base, +/- slot_size otherwise). The module is pure (no VM/PLAT deps) so
// it is unit-tested on the host (tools/slot_reloc_test/).
//
// This sparse offset+type table covers the VM body AND (once containers move
// in-slot) the bundled containers' pointer sites, which the envelope tool
// converts from each container's relocation bitmap and merges in (option A —
// one uniform mechanism, matching the ESP32 firmware-image shape). The VM body
// needs this format because it has Thumb branches (not single-word pointers)
// that a per-word bitmap can't express.
//
// TODO(delta-OTA): bundled containers are pure pointer words, so they could
// instead keep their native position-independent bitmap form (like programs-
// partition images, baked by ImageOutputStream/RelocationBits) rather than
// being baked at slot-A addresses and delta-shifted here. That would keep an
// unchanged container's canonical bytes position-independent, so delta-OTA
// skips re-sending it when the VM body grows and shifts it. See
// docs/ota-relocation-convergence.md.

#ifndef TOIT_SRC_SLOT_RELOC_EC618_H_
#define TOIT_SRC_SLOT_RELOC_EC618_H_

#include <stddef.h>
#include <stdint.h>

namespace toit {

// Relocation direction.
enum SlotRelocDir {
  SLOT_RELOC_TO_SLOT = 1,       // Canonical -> slot (relocate, for writing).
  SLOT_RELOC_TO_CANONICAL = -1, // Slot -> canonical (un-relocate, for reading).
};

// A parsed, zero-copy view over an "SRL2" reloc-table blob. The blob stays
// owned by the caller; this just points into it.
struct SlotRelocTable {
  uint32_t link_base;            // Slot base the image was linked at.
  uint32_t slot_size;            // Slot reservation / spacing.
  uint32_t body_size;            // Populated slot bytes (VM body + extension).
  uint32_t data_size;            // VM .data init image riding after the body
                                 // (verbatim, never relocated; copied to RAM at
                                 // boot). 0 for legacy tables.
  uint32_t abs32_count;          // Number of ABS32 entries.
  uint32_t thmbl_count;          // Number of Thumb-branch-escape entries.
  uint32_t straddle_count;       // Number of sector-straddling branch entries.
  const uint8_t* abs32_varints;  // Delta-varint stream of ABS32 offsets.
  const uint8_t* thmbl_varints;  // Delta-varint stream of branch offsets.
  const uint8_t* straddle_entries;  // Stream of sector-straddling branch
                                 // entries: delta-varint offset followed by
                                 // the site's 4 CANONICAL bytes, each.
  const uint8_t* end;            // One past the blob's last byte.
};

// Parses the "SRL2" header of `blob` (`len` bytes) into `out`. Returns whether
// the magic, sizes and varint streams are well-formed.
bool slot_reloc_parse(const uint8_t* blob, size_t len, SlotRelocTable* table);

// Locates and parses the reloc table stored at the TAIL of a slot. It rides
// there as `[ SRL2 table (N bytes) ][ N : uint32 little-endian ]`, with N the
// slot's very last word — so it is variable-size and self-locating: read the
// last word, then the N bytes before it. The running VM uses this to recover
// its active slot's table and un-relocate reads. `slot` points at the slot
// base (XIP); `slot_size` is the slot reservation. Returns false when no valid
// table is present (e.g. an erased tail reads as 0xffffffff).
bool slot_reloc_parse_trailer(const uint8_t* slot, uint32_t slot_size, SlotRelocTable* table);

// Serializes `table_blob` (an "SRL2" blob of `len` bytes) plus its trailing
// size word into `out`, padded at the FRONT to `out_size` so the result is
// written as the last `out_size` bytes of the slot (the size word lands in the
// slot's last word). `out_size` must be >= len + 4. Returns false otherwise.
// Used by the write path to lay down the tail trailer in one segment-aligned
// block; the leading pad bytes are left as 0xff (erased flash).
bool slot_reloc_build_trailer(const uint8_t* table_blob, uint32_t len,
                              uint8_t* out, uint32_t out_size);

// Applies the table to the window `[window_off, window_off + window_len)` of
// the slot body, in place in `buf` (where `buf[0]` is body offset
// `window_off`). `delta` is `dest_slot_base - link_base`; `dir` selects
// relocate vs un-relocate.
//
// ABS32 words are 4-aligned and windows are sector-aligned, so those sites
// never straddle a window. Thumb-branch sites are 2-aligned: the ones that
// straddle a 4 KB sector boundary are classified at build time into the
// straddle stream, whose entries carry the site's 4 CANONICAL bytes — so the
// applier computes the full relocated site chunk-locally and writes whichever
// part overlaps the window. Stateless for any sector-aligned window split.
//
// Returns whether the window was applied cleanly. Fails (returns false) if a
// site in the regular streams straddles the window boundary — that means the
// caller's windows are not sector-aligned (or the table misclassified a
// site). `delta == 0` is a no-op success.
bool slot_reloc_apply(const SlotRelocTable* table,
                      uint8_t* buf, uint32_t window_off, uint32_t window_len,
                      int32_t delta, SlotRelocDir dir);

// A read-only view that presents the CANONICAL firmware image of a slot and
// un-relocates its body on the fly. The canonical image is table-first:
//
//   [ table_size : u32 ][ SRL2 table ][ VM body + extension ][ VM .data init ]
//
// while the physical slot stores it tail-first:
//
//   [ VM body + ext ][ VM .data init ][ free ][ SRL2 table ][ table_size : word ].
//
// The VM .data init image (`data_size` bytes) rides verbatim right after the
// body in BOTH framings; it is never relocated (it holds no slot pointers that
// the SRL2 table covers — those are fixed up in RAM at boot, see
// toit_data_reloc.c), so the body-window machinery streams it through unchanged.
//
// SlotFirmware maps a canonical offset to its physical source and applies
// `slot_reloc_apply(..., TO_CANONICAL)` to the body, so every reader (the
// integrity SHA, firmware.map, delta-OTA) sees the same link-base bytes
// regardless of which slot is live — and so that SHA covers the reloc table.
//
// LAYOUT INDEPENDENCE: the only board-specific inputs are the slot's read
// pointer, its logical base address, and its reservation size, all passed to
// `open`. The self-locating tail-trailer convention and the table-first
// canonical framing are shared by every ARM board using this relocation scheme;
// a board with different slot geometry constructs SlotFirmware with its own
// base/size and reuses the reconstruction + relocation engine unchanged. No
// EC618 constants (XIP base, load address, slot size) appear here.
//
// The view borrows the slot bytes (e.g. an XIP pointer) and the parsed table
// points into them, so the slot must stay mapped for the view's lifetime.
class SlotFirmware {
 public:
  SlotFirmware() : valid_(false), slot_(nullptr), slot_size_(0),
                   table_blob_(nullptr), table_len_(0), populated_(0),
                   delta_(0), canonical_size_(0) {}

  // Opens a view over the slot whose bytes are at `slot` and whose logical base
  // address is `slot_base_addr` (equal to `slot` on an XIP board), with
  // reservation `slot_size`. Parses the self-locating tail trailer to recover
  // the table and computes `delta = slot_base_addr - link_base`. Returns false
  // when no valid trailer is present or the table is not word-aligned (the
  // builder pads it so the canonical body starts on a 4-byte boundary).
  bool open(const uint8_t* slot, uint32_t slot_base_addr, uint32_t slot_size);

  bool is_valid() const { return valid_; }

  // Size of the canonical image: 4 + table_len + populated + data_size.
  uint32_t canonical_size() const { return canonical_size_; }

  // Returns the single canonical byte at `index` (must be < canonical_size()).
  uint8_t at(uint32_t index) const;

  // Copies canonical bytes [from, to) into `dest`. The body portion of the
  // window must be 4-byte aligned (a block copy from FirmwareMapping guarantees
  // this); single bytes go through `at`. Returns false on a misaligned body
  // window (a reloc site would straddle it) or an out-of-range request.
  bool copy(uint32_t from, uint32_t to, uint8_t* dest) const;

 private:
  // Canonical region starts: [0,4) size word, [4, body_off) table, [body_off,..) body.
  uint32_t body_off() const { return 4 + table_len_; }

  // Un-relocates a body window [wf, wt) in place (TO_CANONICAL). `buf[0]` is body
  // offset `wf`; `wf`/`wt` are 4-byte aligned. ABS32 words are word-aligned and
  // fully contained; Thumb-branch sites are 2-aligned and may straddle `wf`/`wt`,
  // so each is re-encoded from the full 4 bytes in the slot and only its
  // in-window bytes are written. A no-op when the slot already sits at the link
  // base (delta == 0).
  void unrelocate_window(uint8_t* buf, uint32_t wf, uint32_t wt) const;

  bool valid_;
  const uint8_t* slot_;        // Physical slot bytes (body+extension at offset 0).
  uint32_t slot_size_;
  SlotRelocTable table_;       // Parsed tail table (points into `slot_`).
  const uint8_t* table_blob_;  // Raw table bytes inside the slot tail.
  uint32_t table_len_;         // Table length N (the canonical table region size).
  uint32_t populated_;         // Body + extension size (table_.body_size).
  int32_t delta_;              // slot_base_addr - link_base.
  uint32_t canonical_size_;    // 4 + table_len_ + populated_ + table_.data_size.
};

}  // namespace toit

#endif  // TOIT_SRC_SLOT_RELOC_EC618_H_
