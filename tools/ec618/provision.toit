// Copyright (C) 2026 Toit contributors.

// Retargets a provisioned EC618 AP image to a DIFFERENT partition
// descriptor — the "firmware and partition table are independent
// artifacts" promise made real (docs/partition-table-design.md §0):
//
//   1. finds the image's current anchor record (its table names where
//      slot A and the base live — no layout constants here);
//   2. lifts the whole slot-A reservation, un-relocates the VM body back
//      to the canonical (link-base) domain using the merged relocation
//      table at the slot's tail, and re-relocates it to the target
//      descriptor's slot-A address (the same relocate-on-write machinery
//      every OTA uses, host-side);
//   3. erases the old reservation, places the retargeted slot, pads the
//      image to the target reservations, and writes the target anchor
//      record — table and image move as one.
//
// The writer refuses to move partitions that could carry live data
// (type `data`): until a migration journal exists, layout changes may
// only move slots and free space.
//
// Round-trip property (checked by the acceptance test): retargeting to a
// shifted descriptor and back reproduces the original image byte for
// byte.

import cli
import crypto.sha256 show sha256
import host.file
import host.pipe
import io show LITTLE-ENDIAN

import .partitions
import .slot-reloc

// The .binpkg container (built by tools/firmware.toit convert-to-binpkg):
// a 52-byte zero file header, then zones of a 364-byte image header
// (name at 0, data size at 76, subsystem at 336) + the zone's data.
BINPKG-HEADER-SIZE ::= 52
ZONE-HEADER-SIZE ::= 364

main args:
  cmd := cli.Command "provision"
      --help="""
        Retargets a provisioned AP image (slots + anchor record) to a
        different partition descriptor.
        """
      --options=[
        cli.Option "image"
            --help="The provisioned image to retarget: a raw AP image or a .binpkg (auto-detected; the AP zone is retargeted in place)."
            --required,
        cli.Option "out"
            --help="The output image (same container as the input)."
            --required,
        cli.OptionInt "console-uart"
            --help="Override the console/control UART id (default: preserve the source record's).",
        partitions-option,
      ]
      --run=:: run it
  cmd.run args

fail message/string -> none:
  pipe.print-to-stderr "provision: $message"
  exit 1

// Returns the first entry of $type in $entries (Partition list).
first-of entries/List type/string -> Partition?:
  entries.do: | p/Partition | if p.type == type: return p
  return null

run invocation/cli.Invocation -> none:
  input := file.read-contents invocation["image"]
  target/Partitions? := null
  error := catch: target = Partitions.load invocation["partitions"]
  if error: fail "$error"

  // A binpkg starts with its zero-filled 52-byte file header; a raw AP
  // image starts with SDK image content.
  is-binpkg := input.size > BINPKG-HEADER-SIZE and (input[..BINPKG-HEADER-SIZE].every: it == 0)
  out/ByteArray := ?
  if is-binpkg:
    out = input[..BINPKG-HEADER-SIZE].copy
    pos := BINPKG-HEADER-SIZE
    retargeted := false
    while pos + ZONE-HEADER-SIZE <= input.size:
      header := input.copy pos (pos + ZONE-HEADER-SIZE)
      size := LITTLE-ENDIAN.uint32 header 76
      data := input.copy (pos + ZONE-HEADER-SIZE) (pos + ZONE-HEADER-SIZE + size)
      subsystem := header[336..340]
      if subsystem[0] == 'A' and subsystem[1] == 'P':
        data = retarget data target --console=invocation["console-uart"]
        LITTLE-ENDIAN.put-uint32 header 76 data.size
        retargeted = true
      out += header + data
      pos += ZONE-HEADER-SIZE + size
    if not retargeted: fail "no AP zone in the binpkg"
  else:
    out = retarget input target --console=invocation["console-uart"]

  file.write-contents --path=invocation["out"] out
  print "provision: $(target.entries.size)-entry table -> $invocation["out"] ($out.size bytes)"

/**
Retargets the raw AP $image (its slots and anchor record) to the $target
  descriptor and returns the new image.
*/
retarget image/ByteArray target/Partitions --console/int?=null -> ByteArray:
  source-entries := find-anchor-table image
  if source-entries == null:
    fail "no anchor record in the AP image — provision the default layout first (gen-anchor.toit)"

  source-base := first-of source-entries "base"
  source-slot := first-of source-entries "slot"
  source-anchor := first-of source-entries "anchor"
  if source-base == null or source-slot == null or source-anchor == null:
    fail "source table lacks base/slot/anchor entries"

  target-base := first-of target.entries "base"
  target-slot := first-of target.entries "slot"
  slots := target.entries.filter: it.type == "slot"

  // Guardrails: the frozen territory must not move, slot sizes must
  // match (the image is built for its reservation), and data partitions
  // must not move relative to the source (they may hold live bytes).
  if target-base.offset != source-base.offset or target-base.size != source-base.size:
    fail "the base partition cannot move (frozen contract)"
  if (target["anchor"].offset) != source-anchor.offset:
    fail "the anchor cannot move without a base bump (it is the findable spot)"
  if target-slot.size != source-slot.size:
    fail "slot size 0x$(%x target-slot.size) != image's 0x$(%x source-slot.size) — rebuild, don't retarget"
  source-entries.do: | p/Partition |
    if p.type == "data":
      t := target.entries.filter: it.name == p.name
      if t.is-empty or t[0].offset != p.offset or t[0].size != p.size:
        fail "refusing to move/resize data partition '$p.name' (may hold live data; no migration journal yet)"

  // Lift the slot-A reservation and read the merged relocation table at
  // its tail: [ table ][ size : last u32 ].
  src-file := source-slot.offset - source-base.offset
  slot-size := source-slot.size
  if src-file + slot-size > image.size:
    fail "image ($image.size bytes) does not span the source slot reservation"
  slot-bytes := image.copy src-file (src-file + slot-size)
  table-length := LITTLE-ENDIAN.uint32 slot-bytes (slot-size - 4)
  if table-length <= 0 or table-length > slot-size - 4:
    fail "no merged relocation table at the source slot tail"
  merged := SlotRelocTable.parse (slot-bytes.copy (slot-size - 4 - table-length) (slot-size - 4))

  // Un-relocate the body to canonical, re-relocate to the target slot.
  // The .data init and the tail trailer are position-independent and ride
  // along verbatim.
  src-xip := source-slot.offset + target.xip-offset
  tgt-xip := target-slot.offset + target.xip-offset
  body := slot-bytes[.. merged.body-size]
  merged.apply body --base=0 --delta=(src-xip - merged.link-base) --direction=TO-CANONICAL
  merged.apply body --base=0 --delta=(tgt-xip - merged.link-base) --direction=TO-SLOT

  // Assemble: the image proper ends at the source slot-A reservation
  // (this tool handles single-populated-slot images; anything after —
  // extract's legacy whole-image SHA trailer, padding — is dropped and
  // re-derived). Erase the source reservation, place the retargeted
  // slot, pad to the end of the LAST target slot reservation (erased
  // slot B), write the target record, and append a fresh trailer for
  // parity with what `firmware extract` emits.
  content := src-file + slot-size
  last-slot := slots.last
  needed := last-slot.offset + last-slot.size - target-base.offset
  out := ByteArray (max content needed) --initial=0xff
  out.replace 0 image[..content]
  out.fill --from=src-file --to=(src-file + slot-size) 0xff
  tgt-file := target-slot.offset - target-base.offset
  out.replace tgt-file slot-bytes
  anchor-file := source-anchor.offset - source-base.offset
  // Console byte: explicit override, else preserved from the source
  // record (per-device provisioning survives a retarget).
  effective-console := console or (find-anchor-console image) or 0
  out.replace anchor-file (encode-anchor-region target --console=effective-console)

  print "provision: slot A 0x$(%x source-slot.offset) -> 0x$(%x target-slot.offset)"
  return out + (sha256 out)
