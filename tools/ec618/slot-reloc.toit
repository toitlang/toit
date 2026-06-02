// Copyright (C) 2026 Toit contributors.

// Host-side reader + applier for the EC618 "SRL1" slot relocation table.
//
// Mirrors the device C++ in src/slot_reloc_ec618.{h,cc}: the same table
// format, the same ABS32 / Thumb-branch transforms, both directions. The build
// tools (the gen-slot-reloc byte-identity proof, the dual-image builder) share
// this one Toit implementation so the host and device never diverge.

import io show LITTLE-ENDIAN

/** Relocation direction for $SlotRelocTable.apply. */
TO-SLOT ::= 1        // Canonical (link-base) image -> a destination slot.
TO-CANONICAL ::= -1  // A slot -> canonical (link-base) image.

/** The "SRL1" magic, little-endian. */
MAGIC ::= #['S', 'R', 'L', '1']

/**
A parsed EC618 slot relocation table.

Holds the slot geometry and the slot-relative offsets of the two relocation
  kinds: $abs32-offsets (4-byte absolute pointers into the slot) and
  $thmbl-offsets (Thumb branches that escape the slot to a fixed address).
*/
class SlotRelocTable:
  link-base/int
  slot-size/int
  body-size/int
  abs32-offsets/List
  thmbl-offsets/List

  constructor --.link-base --.slot-size --.body-size --.abs32-offsets --.thmbl-offsets:

  /** Parses an "SRL1" $blob (as written by tools/ec618/gen-slot-reloc.toit). */
  constructor.parse blob/ByteArray:
    if blob.size < 24: throw "SRL1 table too small"
    4.repeat: if blob[it] != MAGIC[it]: throw "bad SRL1 magic"
    link-base = LITTLE-ENDIAN.uint32 blob 4
    slot-size = LITTLE-ENDIAN.uint32 blob 8
    body-size = LITTLE-ENDIAN.uint32 blob 12
    abs32-count := LITTLE-ENDIAN.uint32 blob 16
    thmbl-count := LITTLE-ENDIAN.uint32 blob 20
    pos := 24
    abs32 := []
    previous := 0
    abs32-count.repeat:
      result := read-varint blob pos
      previous += result[0]
      abs32.add previous
      pos = result[1]
    thmbl := []
    previous = 0
    thmbl-count.repeat:
      result := read-varint blob pos
      previous += result[0]
      thmbl.add previous
      pos = result[1]
    abs32-offsets = abs32
    thmbl-offsets = thmbl

  /**
  Relocates the slot content in $bytes in place by $delta.

  $base is the file offset of the slot's first byte within $bytes; the stored
    offsets are slot-relative. $direction selects relocate ($TO-SLOT) vs
    un-relocate ($TO-CANONICAL). A no-op when $delta is 0.
  */
  apply bytes/ByteArray --base/int --delta/int --direction/int -> none:
    if delta == 0: return
    word-delta := direction == TO-SLOT ? delta : -delta
    branch-delta := -word-delta
    abs32-offsets.do: | offset/int |
      p := base + offset
      word := LITTLE-ENDIAN.uint32 bytes p
      LITTLE-ENDIAN.put-uint32 bytes p ((word + word-delta) & 0xffffffff)
    thmbl-offsets.do: | offset/int |
      p := base + offset
      imm := thumb-branch-imm bytes p
      put-thumb-branch-imm bytes p (imm + branch-delta)

/** Reads an unsigned LEB128 varint at $pos in $bytes; returns `[value, next-pos]`. */
read-varint bytes/ByteArray pos/int -> List:
  value := 0
  shift := 0
  while true:
    b := bytes[pos++]
    value |= (b & 0x7f) << shift
    if (b & 0x80) == 0: return [value, pos]
    shift += 7

/**
Decodes the signed branch immediate of a Thumb-2 BL/B.W at $offset in $bytes.

The immediate is PC-relative to the instruction address + 4.
*/
thumb-branch-imm bytes/ByteArray offset/int -> int:
  lo := LITTLE-ENDIAN.uint16 bytes offset
  hi := LITTLE-ENDIAN.uint16 bytes (offset + 2)
  s := (lo >> 10) & 1
  imm10 := lo & 0x3ff
  j1 := (hi >> 13) & 1
  j2 := (hi >> 11) & 1
  imm11 := hi & 0x7ff
  i1 := (j1 ^ s) ^ 1
  i2 := (j2 ^ s) ^ 1
  imm := (s << 24) | (i1 << 23) | (i2 << 22) | (imm10 << 12) | (imm11 << 1)
  if (imm & 0x01000000) != 0: imm -= 0x02000000
  return imm

/** Writes a Thumb-2 BL/B.W at $offset in $bytes with signed branch immediate $imm. */
put-thumb-branch-imm bytes/ByteArray offset/int imm/int -> none:
  imm &= 0x01ffffff
  s := (imm >> 24) & 1
  i1 := (imm >> 23) & 1
  i2 := (imm >> 22) & 1
  imm10 := (imm >> 12) & 0x3ff
  imm11 := (imm >> 1) & 0x7ff
  j1 := (i1 ^ 1) ^ s
  j2 := (i2 ^ 1) ^ s
  lo-old := LITTLE-ENDIAN.uint16 bytes offset
  hi-old := LITTLE-ENDIAN.uint16 bytes (offset + 2)
  lo := (lo-old & 0xf800) | (s << 10) | imm10
  hi := (hi-old & 0xd000) | (j1 << 13) | (j2 << 11) | imm11
  LITTLE-ENDIAN.put-uint16 bytes offset lo
  LITTLE-ENDIAN.put-uint16 bytes (offset + 2) hi
