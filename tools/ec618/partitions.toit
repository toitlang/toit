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
XIP-OFFSET ::= 0x80_0000
SCHEMA-URL ::= "https://toit.io/schemas/ec618/partition-table/v1.json"
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
Returns the shared --partitions option for host tools that read the
  descriptor. The default path is relative to the repository root, where
  the Makefile runs the tools.
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

  Throws with a readable message on a missing file, a gap/overlap, a
    misaligned entry, or incomplete coverage of the flash.
  */
  constructor.load path/string=DEFAULT-DESCRIPTOR-PATH:
    if not file.is-file path:
      throw "partition descriptor not found at '$path' (run from the repo root or pass --partitions)"
    return Partitions.from-document (yaml.decode (file.read-contents path))

  /** Loads and validates an already-decoded YAML document. */
  constructor.from-document doc/any:
    if doc is not Map: throw "partition descriptor must be a map"
    check-keys_ doc ["\$schema", "xip-offset", "partitions"] "descriptor"
    if (doc.get "\$schema" --if-absent=(: null)) != SCHEMA-URL:
      throw "partition descriptor must use schema '$SCHEMA-URL'"
    xip := doc.get "xip-offset" --if-absent=(: null)
    if xip is not int or xip != XIP-OFFSET:
      throw "EC618 xip-offset must be 0x800000"
    xip-offset = xip
    partitions := doc.get "partitions" --if-absent=(: null)
    if partitions is not List or not 1 <= partitions.size <= ANCHOR-MAX-ENTRIES:
      throw "partitions must be a list of 1..$ANCHOR-MAX-ENTRIES entries"
    entries = []
    by-name_ = {:}
    cursor := 0
    partitions.do: |p/any|
      if p is not Map: throw "partition entry must be a map"
      check-keys_ p ["name", "type", "offset", "size"] "partition"
      name := p.get "name" --if-absent=(: null)
      if name is not string or name.is-empty or name.size > MAX-NAME-SIZE or (name.contains "\u0000"):
        throw "partition name must contain 1..$MAX-NAME-SIZE UTF-8 bytes without NUL"
      type := p.get "type" --if-absent=(: null)
      if type is not string or not (TYPE-CODES.contains type):
        throw "$name: unknown partition type '$type'"
      size := p.get "size" --if-absent=(: null)
      offset := p.get "offset" --if-absent=(: cursor)
      if size is not int or not 0 < size <= FLASH-END:
        throw "$name: size must be an integer in 1..$FLASH-END"
      if offset is not int or not 0 <= offset < FLASH-END:
        throw "$name: offset must be an integer in 0..$(FLASH-END - 1)"
      if offset != cursor:
        throw "$name: starts at 0x$(%x offset), expected 0x$(%x cursor) (gap or overlap)"
      if offset % SECTOR != 0 or size % SECTOR != 0:
        throw "$name: offset/size not 4 KiB aligned"
      if size > FLASH-END - offset:
        throw "$name: extends beyond EC618 flash"
      if by-name_.contains name: throw "$name: duplicate entry"
      entry := Partition name type offset size
      entries.add entry
      by-name_[name] = entry
      cursor = offset + size
    if cursor != FLASH-END:
      throw "table covers 0x$(%x cursor), expected 0x$(%x FLASH-END)"
    validate-layout entries

  /** Returns the entry called $name; throws if there is none. */
  operator [] name/string -> Partition:
    return by-name_.get name --if-absent=: throw "no partition '$name' in the descriptor"

  /** Returns the XIP (memory-mapped) address of the partition called $name. */
  xip name/string -> int:
    return this[name].offset + xip-offset

check-keys_ object/Map allowed/List context/string -> none:
  object.keys.do: |key|
    if not (allowed.contains key): throw "$context: unknown property '$key'"

/** Checks the layout assumptions shared by the EC618 build and runtime. */
validate-layout entries/List -> none:
  ["base", "base-id", "anchor"].do: |role/string|
    matches := entries.filter: it.type == role
    if matches.size != 1 or matches.first.name != role:
      throw "layout requires exactly one '$role' partition named '$role'"
  base := (entries.filter: it.type == "base").first
  base-id := (entries.filter: it.type == "base-id").first
  anchor := (entries.filter: it.type == "anchor").first
  if base.offset != 0x24000: throw "base must start at the EC618 AP load offset 0x24000"
  if base-id.offset != base.offset + base.size or base-id.size != SECTOR:
    throw "base-id must be one sector immediately after base"
  if anchor.size != 2 * SECTOR or anchor.offset < base-id.offset + base-id.size:
    throw "anchor must be two sectors after base-id"
  slots := entries.filter: it.type == "slot"
  if slots.size != 2: throw "layout requires exactly two VM slots"
  if slots[0].size != slots[1].size: throw "VM slots must have equal sizes"
  if slots[0].offset < anchor.offset + anchor.size:
    throw "VM slots must follow the anchor"
  registry := entries.filter: it.name == "registry"
  if registry.size != 1 or registry.first.type != "data":
    throw "layout requires a data partition named 'registry'"
  if registry.first.offset < slots[1].offset + slots[1].size:
    throw "registry must follow both VM slots"

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
Encodes the provisioning anchor record for $parts: boot state
  { active='A', pending=0, state=NONE, seq=1 } plus the known-good
  configuration. The trial configuration is empty until an OTA is staged.

The $console byte selects the console/control UART (0/1/2, or
  $ANCHOR-CONSOLE-OFF) attached to the initially known-good image.
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
Encodes the full anchor region for $parts: sector 0 carries the
  provisioning record, sector 1 stays erased (the ping-pong partner).
*/
encode-anchor-region parts/Partitions --console/int=0 -> ByteArray:
  region := ByteArray (2 * ANCHOR-SECTOR) --initial=0xff
  region.replace 0 (encode-anchor-record parts --console=console)
  return region

/** A validated anchor record and its known-good and optional trial layouts. */
class AnchorRecord:
  offset/int
  seq/int
  active/int
  pending/int
  state/int
  parts/Partitions
  console/int
  pending-parts/Partitions?
  pending-console/int

  constructor .offset .seq .active .pending .state .parts .console .pending-parts .pending-console:

/**
Returns the known-good console of the newest anchor record in the AP $image,
  or null when there is no valid record. Invalid tables throw a readable error.
*/
find-anchor-console image/ByteArray -> int?:
  record := find-anchor-record image
  return record == null ? null : record.console

/**
Returns the known-good table of the newest anchor record in the AP $image,
  or null when there is no valid record. Invalid tables throw a readable error.
*/
find-anchor-table image/ByteArray -> List?:
  record := find-anchor-record image
  return record == null ? null : record.parts.entries

/**
Returns the anchor of a static provisioning image, or null when none is found.

Requires the initial slot-A record and its erased partner, exactly as emitted
  by $encode-anchor-region. Device dumps with OTA history are not static build
  inputs: resetting their boot state could discard the known-good/trial choice.
*/
find-provisioning-anchor image/ByteArray -> AnchorRecord?:
  record := find-anchor-record image
  if record == null: return null
  offset := record.parts["anchor"].offset - record.parts["base"].offset
  initial := encode-anchor-region record.parts --console=record.console
  if image[offset..offset + initial.size] != initial:
    throw "AP image must carry an initial provisioning anchor; live OTA state cannot be retargeted"
  return record

/**
Finds the newest anchor record in an AP image whose first byte maps to 0x24000.

Checks header state and CRC before decoding either table. Both tables must
  describe complete valid layouts and identify the record's own two-sector
  region. The highest sequence wins, with the lower sector winning ties,
  matching the bootloader. Distinct anchor regions are ambiguous and rejected.

An invalid table in a CRC-valid record throws rather than silently falling
  back to an older configuration. A torn record with an invalid CRC or header
  can fall back to its valid partner, as it does on the device.
*/
find-anchor-record image/ByteArray -> AnchorRecord?:
  best/AnchorRecord? := null
  region/int? := null
  for off := 0; off + ANCHOR-HEADER-SIZE + ANCHOR-TRAILER-SIZE <= image.size; off += ANCHOR-SECTOR:
    if not (valid-anchor-header_ image off): continue
    active-count := image[off + 10]
    pending-count := image[off + 11]
    count := active-count + pending-count
    end := off + ANCHOR-HEADER-SIZE + count * ANCHOR-ENTRY-SIZE
    if end + ANCHOR-TRAILER-SIZE > image.size: continue
    if (anchor-crc_ image[off..end]) != (LITTLE-ENDIAN.uint32 image end): continue
    parts := decode-anchor-table_ image (off + ANCHOR-HEADER-SIZE) active-count
    anchor := parts["anchor"].offset - parts["base"].offset
    // A copy of an anchor embedded in a slot or free sector is not the
    // record stored at the table's declared anchor address.
    if off != anchor and off != anchor + ANCHOR-SECTOR: continue
    if anchor + 2 * ANCHOR-SECTOR > image.size:
      throw "AP image does not contain the complete anchor region"
    pending-parts/Partitions? := null
    if pending-count != 0:
      pending-parts = decode-anchor-table_ image
          (off + ANCHOR-HEADER-SIZE + active-count * ANCHOR-ENTRY-SIZE)
          pending-count
      if pending-parts["anchor"].offset != parts["anchor"].offset:
        throw "trial table moves the anchor region"
      if pending-parts["base"].size != parts["base"].size:
        throw "trial table changes the frozen base"
    if region != null and region != anchor:
      throw "multiple anchor regions in the AP image"
    region = anchor
    seq := LITTLE-ENDIAN.uint32 image (off + 4)
    if best == null or seq > best.seq:
      best = AnchorRecord off seq image[off + 8] image[off + 9] image[off + 3]
          parts
          image[off + 12]
          pending-parts
          image[off + 13]
  return best

valid-anchor-header_ image/ByteArray off/int -> bool:
  if (LITTLE-ENDIAN.uint16 image off) != ANCHOR-MAGIC or image[off + 2] != ANCHOR-VERSION:
    return false
  active := image[off + 8]
  pending := image[off + 9]
  state := image[off + 3]
  if active != 'A' and active != 'B': return false
  if not (valid-console_ image[off + 12]): return false
  if not 1 <= image[off + 10] <= ANCHOR-MAX-ENTRIES or image[off + 11] > ANCHOR-MAX-ENTRIES:
    return false
  if pending == 0:
    return state == 0 and image[off + 11] == 0
  return (pending == 'A' or pending == 'B') and pending != active and
      (state == 1 or state == 2) and image[off + 11] != 0 and (valid-console_ image[off + 13])

valid-console_ console/int -> bool:
  return 0 <= console <= 2 or console == ANCHOR-CONSOLE-OFF

decode-anchor-table_ image/ByteArray offset/int count/int -> Partitions:
  codes := {:}
  TYPE-CODES.do: |name/string code/int| codes[code] = name
  entries := []
  count.repeat: |i/int|
    entry := offset + i * ANCHOR-ENTRY-SIZE
    name-bytes := image[entry..entry + 16]
    end := name-bytes.index-of 0
    if end <= 0 or not (name-bytes[end..].every: it == 0):
      throw "anchor partition name must be nonempty and NUL-padded"
    if not (name-bytes.is-valid-string-content 0 end):
      throw "anchor partition name is not valid UTF-8"
    name := name-bytes.to-string 0 end
    entries.add {
      "name": name,
      "type": codes.get image[entry + 24] --if-absent=(: null),
      "offset": LITTLE-ENDIAN.uint32 image (entry + 16),
      "size": LITTLE-ENDIAN.uint32 image (entry + 20),
    }
  return Partitions.from-document {
    "\$schema": SCHEMA-URL,
    "xip-offset": XIP-OFFSET,
    "partitions": entries,
  }
