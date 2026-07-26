// Copyright (C) 2026 Toit contributors.

// Shared loader for the EC618 partition descriptor
// (toolchains/ec618/partitions.yaml — the single source of truth for the
// flash layout).
//
// Entries may omit `offset`: it is then derived as the end of the previous
// entry. This is how the anchor chain stays soft — base-id starts wherever
// the base ends, the slots wherever base-id ends — so a future base-size
// change is a one-line `size:` edit, not a cascade of address edits. An
// explicit `offset` is an EXTERNAL constraint (boot-ROM, SDK or live-data
// address) and doubles as an assertion: the derivation must land the chain
// exactly there, or loading fails.

import cli
import crypto.crc show Crc
import encoding.yaml
import host.file
import io show Buffer LITTLE-ENDIAN

DEFAULT-DESCRIPTOR-PATH ::= "toolchains/ec618/partitions.yaml"
FLASH-END ::= 0x40_0000
SECTOR ::= 0x1000

/**
Partition types, numbered as stored in the anchor record's table entries.

Mirrors the PARTITION_TYPE_* enum in toolchains/ec618/project/inc/anchor.h.
*/
TYPE-CODES ::= {
  "locked": 1,
  "base": 2,
  "base-id": 3,
  "anchor": 4,
  "slot": 5,
  "data": 6,
  "free": 7,
}

// The anchor record stores names as NUL-padded char[16].
MAX-NAME-SIZE ::= 15

/**
Returns the shared --partitions option for host tools that read the descriptor. The default path is relative to the repository root, where the Makefile runs the tools.
*/
partitions-option -> cli.Option:
  return cli.Option "partitions"
      --help="The partition descriptor (partitions.yaml)."
      --default=DEFAULT-DESCRIPTOR-PATH

class Partition:
  name/string
  type/string
  offset/int
  size/int

  constructor .name .type .offset .size:

class Partitions:
  xip-offset/int
  entries/List  // Of $Partition, in flash order.
  by-name_/Map

  /**
  Loads and validates the descriptor at $path.

  Throws with a readable message on a missing file, a gap/overlap, a misaligned entry, or incomplete coverage of the flash.
  */
  constructor.load path/string=DEFAULT-DESCRIPTOR-PATH:
    if not file.is-file path:
      throw "partition descriptor not found at '$path' (run from the repo root or pass --partitions)"
    doc := yaml.decode (file.read-contents path)
    xip-offset = doc["xip-offset"]
    entries = []
    by-name_ = {:}
    cursor := 0
    doc["partitions"].do: | p/Map |
      name := p["name"]
      size := p["size"]
      offset := p.get "offset" --if-absent=: cursor
      if offset != cursor:
        throw "$name: starts at 0x$(%x offset), expected 0x$(%x cursor) (gap or overlap)"
      if offset % SECTOR != 0 or size % SECTOR != 0:
        throw "$name: offset/size not 4 KiB aligned"
      if size <= 0:
        throw "$name: empty"
      if name.size > MAX-NAME-SIZE:
        throw "$name: name longer than $MAX-NAME-SIZE bytes (anchor record limit)"
      if not TYPE-CODES.contains p["type"]:
        throw "$name: unknown type '$p["type"]'"
      if by-name_.contains name:
        throw "$name: duplicate entry"
      entry := Partition name p["type"] offset size
      entries.add entry
      by-name_[name] = entry
      cursor = offset + size
    if cursor != FLASH-END:
      throw "table covers 0x$(%x cursor), expected 0x$(%x FLASH-END)"

  /** Returns the entry called $name; throws if there is none. */
  operator [] name/string -> Partition:
    return by-name_.get name --if-absent=: throw "no partition '$name' in the descriptor"

  /** Returns the XIP (memory-mapped) address of the partition called $name. */
  xip name/string -> int:
    return this[name].offset + xip-offset

// The anchor record's on-flash format (anchor.h, design doc §0.1):
// header 16B { magic, version, state, seq, active, pending,
//              active-count, pending-count, active-console, pending-console }
// + active entries + pending entries + 16B CRC trailer.
ANCHOR-MAGIC ::= 0x4154  // Reads as 'T','A' on flash (little-endian).
ANCHOR-VERSION ::= 3
ANCHOR-SECTOR ::= 0x1000
ANCHOR-HEADER-SIZE ::= 16
ANCHOR-ENTRY-SIZE ::= 32
ANCHOR-TRAILER-SIZE ::= 16
// Mirrors ANCHOR_MAX_ENTRIES in anchor.h — the device-side staging cap.
ANCHOR-MAX-ENTRIES ::= 32

// Mirrors ANCHOR_SENTINEL_BYTES in anchor.h. An unprovisioned base carries
// this locator at the descriptor-selected anchor offset; gen-anchor replaces
// it with the first record only after checking it.
ANCHOR-SENTINEL ::= #[
  'T', 'O', 'I', 'T', '-', 'A', 'N', 'C',
  'H', 'O', 'R', '-', 'V', '1', 0xa5, 0x5a,
]

anchor-crc_ bytes/ByteArray -> int:
  crc := Crc.little-endian 32 --polynomial=0xEDB88320 --initial-state=0xffff_ffff --xor-result=0xffff_ffff
  crc.add bytes
  return crc.get-as-int

ANCHOR-CONSOLE-OFF ::= 0xff

/**
Encodes the provisioning anchor record for $parts: boot state { active='A', pending=0, state=NONE, seq=1 } plus the known-good configuration. The trial configuration is empty until an OTA is staged.

The $console byte selects the console/control UART (0/1/2, or $ANCHOR-CONSOLE-OFF) attached to the initially known-good image.
*/
encode-anchor-record parts/Partitions --console/int=0 -> ByteArray:
  entries := parts.entries
  if entries.size > ANCHOR-MAX-ENTRIES:
    throw "$entries.size entries exceed the device cap of $ANCHOR-MAX-ENTRIES"
  if console != ANCHOR-CONSOLE-OFF and not 0 <= console <= 2:
    throw "console UART must be 0, 1, 2, or $ANCHOR-CONSOLE-OFF"
  buffer := Buffer
  le := buffer.little-endian
  le.write-uint16 ANCHOR-MAGIC
  buffer.write-byte ANCHOR-VERSION
  buffer.write-byte 0    // SLOT_STATE_NONE: no trial in progress.
  le.write-uint32 1      // seq = 1.
  buffer.write-byte 'A'  // Known-good slot.
  buffer.write-byte 0    // No pending trial.
  buffer.write-byte entries.size  // Known-good table.
  buffer.write-byte 0             // No trial table.
  buffer.write-byte console       // Known-good console.
  buffer.write-byte ANCHOR-CONSOLE-OFF
  buffer.write (ByteArray 2)      // Reserved header bytes.
  entries.do: | p/Partition |
    name := p.name.to-byte-array
    buffer.write name
    buffer.write (ByteArray (16 - name.size))
    le.write-uint32 p.offset
    le.write-uint32 p.size
    buffer.write-byte TYPE-CODES[p.type]
    buffer.write (ByteArray 7)  // Reserved.
  body := buffer.bytes
  le.write-uint32 (anchor-crc_ body)
  buffer.write (ByteArray 12 --initial=0xff)
  return buffer.bytes

/**
Encodes the full anchor region for $parts: sector 0 carries the provisioning record, sector 1 stays erased (the ping-pong partner).
*/
encode-anchor-region parts/Partitions --console/int=0 -> ByteArray:
  region := ByteArray (2 * ANCHOR-SECTOR) --initial=0xff
  region.replace 0 (encode-anchor-record parts --console=console)
  return region

/**
Returns the known-good console byte of the anchor record found in the AP $image, or null when the image carries no valid record.
*/
find-anchor-console image/ByteArray -> int?:
  offset := find-anchor-offset_ image
  return offset == null ? null : image[offset + 12]

/**
Finds the anchor record in the AP $image (4 KiB-aligned scan for magic + a valid CRC) and returns its table as a list of $Partition.

Returns null when the image carries no valid record.
*/
find-anchor-table image/ByteArray -> List?:
  off := find-anchor-offset_ image
  if off == null: return null
  count := image[off + 10]
  codes := {:}  // Type code -> name.
  TYPE-CODES.do: | name/string code/int | codes[code] = name
  entries := []
  count.repeat: | i/int |
    entry := off + ANCHOR-HEADER-SIZE + i * ANCHOR-ENTRY-SIZE
    name-bytes := image[entry .. entry + 16]
    end := name-bytes.index-of 0
    name := (name-bytes[.. end < 0 ? 16 : end]).to-string
    entries.add (Partition name
        codes[image[entry + 24]]
        (LITTLE-ENDIAN.uint32 image (entry + 16))
        (LITTLE-ENDIAN.uint32 image (entry + 20)))
  return entries

// Returns the file offset of the valid anchor record in $image, or null.
find-anchor-offset_ image/ByteArray -> int?:
  for off := 0; off + 32 <= image.size; off += ANCHOR-SECTOR:
    if (LITTLE-ENDIAN.uint16 image off) != ANCHOR-MAGIC: continue
    if image[off + 2] != ANCHOR-VERSION: continue
    active-count := image[off + 10]
    pending-count := image[off + 11]
    count := active-count + pending-count
    record-size := ANCHOR-HEADER-SIZE + count * ANCHOR-ENTRY-SIZE + ANCHOR-TRAILER-SIZE
    if active-count == 0 or
        active-count > ANCHOR-MAX-ENTRIES or
        pending-count > ANCHOR-MAX-ENTRIES or
        off + record-size > image.size:
      continue
    if (anchor-crc_ image[off .. off + record-size - ANCHOR-TRAILER-SIZE]) != (LITTLE-ENDIAN.uint32 image (off + record-size - ANCHOR-TRAILER-SIZE)): continue
    return off
  return null
