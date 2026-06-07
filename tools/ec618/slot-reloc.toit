// Copyright (C) 2026 Toit contributors.

// Host-side reader + applier for the EC618 "SRL1" slot relocation table.
//
// Mirrors the device C++ in src/slot_reloc_ec618.{h,cc}: the same table
// format, the same ABS32 / Thumb-branch transforms, both directions. The build
// tools (the gen-slot-reloc byte-identity proof, the dual-image builder) share
// this one Toit implementation so the host and device never diverge.

import io show Buffer LITTLE-ENDIAN

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
  // Size of the VM's writable .data init image that rides in the slot after the
  // body+extension (verbatim, NOT relocated — the device copies it into RAM at
  // boot and relocate_data_slot_pointers fixes the slot pointers there). Lets an
  // OTA carry each firmware's own .data. 0 for legacy tables.
  data-size/int
  abs32-offsets/List
  thmbl-offsets/List

  constructor --.link-base --.slot-size --.body-size --.data-size=0 --.abs32-offsets --.thmbl-offsets:

  /** Parses an "SRL1" $blob (as written by tools/ec618/gen-slot-reloc.toit). */
  constructor.parse blob/ByteArray:
    if blob.size < 28: throw "SRL1 table too small"
    4.repeat: if blob[it] != MAGIC[it]: throw "bad SRL1 magic"
    link-base = LITTLE-ENDIAN.uint32 blob 4
    slot-size = LITTLE-ENDIAN.uint32 blob 8
    body-size = LITTLE-ENDIAN.uint32 blob 12
    abs32-count := LITTLE-ENDIAN.uint32 blob 16
    thmbl-count := LITTLE-ENDIAN.uint32 blob 20
    data-size = LITTLE-ENDIAN.uint32 blob 24
    pos := 28
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

  /**
  Serializes this table to the "SRL1" wire format (the inverse of
    $SlotRelocTable.parse).

  The header is $MAGIC followed by $link-base, $slot-size, $body-size and the
    two counts (all little-endian uint32); the $abs32-offsets and $thmbl-offsets
    lists (slot-relative, ascending) follow as delta-encoded unsigned LEB128
    varints. Mirrors `encode-table` in tools/ec618/gen-slot-reloc.toit.
  */
  to-bytes -> ByteArray:
    buffer := Buffer
    buffer.write MAGIC
    le := buffer.little-endian
    le.write-uint32 link-base
    le.write-uint32 slot-size
    le.write-uint32 body-size
    le.write-uint32 abs32-offsets.size
    le.write-uint32 thmbl-offsets.size
    le.write-uint32 data-size
    write-varint-deltas buffer abs32-offsets
    write-varint-deltas buffer thmbl-offsets
    return buffer.bytes

  /**
  Returns a copy of this table extended with the in-slot extension pointers.

  The bundled extension (container images, the image table, the patched
    `DromData.extension`) is laid out inside the slot after the VM body, so its
    absolute pointers move with the slot exactly like the VM body's ABS32
    pointers. $extra-abs32 holds their slot-relative offsets; they are merged
    into $abs32-offsets (sorted, de-duplicated) so the device's single
    relocate-on-write / un-relocate-on-read pass fixes the whole slot uniformly
    (option A, see docs/ota-relocation-convergence.md).

  $populated-size becomes the new $body-size: the populated front of the slot
    (VM body + extension), i.e. where the free region and tail trailer begin.
    The branch ($thmbl-offsets) set is unchanged — the extension has no
    slot-escaping branches, only data pointers.
  */
  merge-extension --extra-abs32/List --populated-size/int -> SlotRelocTable:
    merged := abs32-offsets + extra-abs32
    merged.sort --in-place
    deduped := []
    merged.do: | offset/int |
      if deduped.is-empty or deduped.last != offset: deduped.add offset
    return SlotRelocTable
        --link-base=link-base
        --slot-size=slot-size
        --body-size=populated-size
        --data-size=data-size
        --abs32-offsets=deduped
        --thmbl-offsets=thmbl-offsets

/** Reads an unsigned LEB128 varint at $pos in $bytes; returns `[value, next-pos]`. */
read-varint bytes/ByteArray pos/int -> List:
  value := 0
  shift := 0
  while true:
    b := bytes[pos++]
    value |= (b & 0x7f) << shift
    if (b & 0x80) == 0: return [value, pos]
    shift += 7

/** Writes the ascending $offsets to $buffer as delta-encoded unsigned LEB128 varints. */
write-varint-deltas buffer/Buffer offsets/List -> none:
  previous := 0
  offsets.do: | offset/int |
    write-varint buffer (offset - previous)
    previous = offset

/** Writes $value to $buffer as an unsigned LEB128 varint. */
write-varint buffer/Buffer value/int -> none:
  while true:
    b := value & 0x7f
    value >>= 7
    if value != 0:
      buffer.write-byte (b | 0x80)
    else:
      buffer.write-byte b
      return

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
