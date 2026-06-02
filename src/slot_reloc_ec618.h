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
// relocation table (the "SRL1" artifact, see tools/ec618/gen-slot-reloc.toit).
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

// A parsed, zero-copy view over an "SRL1" reloc-table blob. The blob stays
// owned by the caller; this just points into it.
struct SlotRelocTable {
  uint32_t link_base;            // Slot base the image was linked at.
  uint32_t slot_size;            // Slot reservation / spacing.
  uint32_t body_size;            // Populated slot bytes.
  uint32_t abs32_count;          // Number of ABS32 entries.
  uint32_t thmbl_count;          // Number of Thumb-branch-escape entries.
  const uint8_t* abs32_varints;  // Delta-varint stream of ABS32 offsets.
  const uint8_t* thmbl_varints;  // Delta-varint stream of branch offsets.
  const uint8_t* end;            // One past the blob's last byte.
};

// Parses the "SRL1" header of `blob` (`len` bytes) into `out`. Returns whether
// the magic, sizes and varint streams are well-formed.
bool slot_reloc_parse(const uint8_t* blob, size_t len, SlotRelocTable* table);

// Applies the table to the window `[window_off, window_off + window_len)` of
// the slot body, in place in `buf` (where `buf[0]` is body offset
// `window_off`). `delta` is `dest_slot_base - link_base`; `dir` selects
// relocate vs un-relocate. Only entries whose 4-byte patch site lies fully
// inside the window are applied.
//
// Returns whether the window was applied cleanly. Fails (returns false) if a
// patch site straddles the window boundary — the caller must align windows so
// every entry is fully contained (sector-aligned windows satisfy this; the
// build-time check in gen-slot-reloc keeps branch sites off sector edges).
// `delta == 0` is a no-op success.
bool slot_reloc_apply(const SlotRelocTable* table,
                      uint8_t* buf, uint32_t window_off, uint32_t window_len,
                      int32_t delta, SlotRelocDir dir);

}  // namespace toit

#endif  // TOIT_SRC_SLOT_RELOC_EC618_H_
