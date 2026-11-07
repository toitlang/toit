// Copyright (C) 2026 Toit contributors.

// Retargets a provisioned EC618 AP image to a DIFFERENT partition
// descriptor — the "firmware and partition table are independent
// artifacts" contract:
//
//   1. reads the partition table embedded in the input AP image's anchor
//      record (that table names where slot A and the base currently live;
//      there is no separate user-managed "source record");
//   2. lifts the whole slot-A reservation, un-relocates the VM body back
//      to the canonical (link-base) domain using the merged relocation
//      table at the slot's tail, and re-relocates it to the target
//      descriptor's slot-A address (the same relocate-on-write machinery
//      every OTA uses, host-side);
//   3. erases the old reservation, places the retargeted slot, pads the
//      image to the target reservations, and writes the target anchor
//      record — table and image move as one;
//   4. normalizes the AP image through the end of the target's last slot
//      reservation and appends one fresh SHA-256 trailer. The compact image
//      emitted by `firmware extract` ends after slot A and therefore becomes
//      canonical on its first pass.
//
// The writer preserves all fixed partitions: until a migration journal
// exists, layout changes may only move slots and free space. The AP
// checksum must be valid, and all bytes following slot A must be erased.
//
// Round-trip property (checked by the acceptance test): retargeting to a
// shifted descriptor and back reproduces the original image byte for
// byte.

import cli
import crypto.sha256 show sha256
import host.file
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
        Retargets a provisioned AP image to a different partition
        descriptor. The input layout comes from the anchor record already
        embedded in --image; --partitions selects the output layout. The
        output AP zone is normalized through the end of the selected
        descriptor's last slot reservation.
        """
      --options=[
        cli.Option "image"
            --help="The provisioned image to retarget: a raw AP image or a .binpkg (auto-detected; the AP zone is retargeted in place)."
            --required,
        cli.Option "out"
            --help="The output image (same container as the input)."
            --required,
        cli.OptionInt "console-uart"
            --help="Override the console/control UART id stored in the output anchor record (default: preserve the value embedded in the input image).",
        partitions-option,
      ]
      --run=:: run it
  cmd.run args

// Returns the first entry of $type in $entries (Partition list).
first-of entries/List type/string -> Partition?:
  entries.do: | p/Partition | if p.type == type: return p
  return null

run invocation/cli.Invocation -> none:
  ui := invocation.cli.ui
  input := file.read-contents invocation["image"]
  target/Partitions? := null
  error := catch: target = Partitions.load invocation["partitions"]
  if error: ui.abort "$error"

  out := retarget-container input target
      --ui=ui
      --console=invocation["console-uart"]

  file.write-contents --path=invocation["out"] out
  print "provision: $(target.entries.size)-entry table -> $invocation["out"] ($out.size bytes)"

/**
Retargets the AP image in $input and returns the same container type.

The AP image may be raw or embedded in a binpkg and must have a valid SHA-256
  trailer, as emitted by firmware extraction. Every other binpkg zone is
  preserved byte for byte. A binpkg must contain complete zone records and
  exactly one AP zone. Its structure is validated before retargeting that zone.
*/
retarget-container input/ByteArray target/Partitions --ui/cli.Ui --console/int?=null -> ByteArray:
  // A binpkg starts with its zero-filled 52-byte file header; a raw AP
  // image starts with SDK image content.
  is-binpkg := input.size >= BINPKG-HEADER-SIZE and (input[..BINPKG-HEADER-SIZE].every: it == 0)
  out/ByteArray := ?
  if is-binpkg:
    pos := BINPKG-HEADER-SIZE
    zones := []
    ap-index/int? := null
    while pos < input.size:
      if input.size - pos < ZONE-HEADER-SIZE:
        ui.abort "truncated binpkg zone header at byte $pos"
      header := input[pos .. pos + ZONE-HEADER-SIZE]
      size := LITTLE-ENDIAN.uint32 header 76
      data-start := pos + ZONE-HEADER-SIZE
      if size > input.size - data-start:
        ui.abort "truncated binpkg zone data at byte $data-start: need $size bytes, have $(input.size - data-start)"
      data := input[data-start .. data-start + size]
      if header[336..340] == #['A', 'P', 0, 0]:
        if ap-index != null: ui.abort "multiple AP zones in the binpkg"
        ap-index = zones.size
      zones.add [header, data]
      pos = data-start + size
    if ap-index == null: ui.abort "no AP zone in the binpkg"
    out = input[..BINPKG-HEADER-SIZE].copy
    zones.size.repeat: |index/int|
      zone := zones[index]
      header/ByteArray := zone[0]
      data/ByteArray := zone[1]
      if index == ap-index:
        data = retarget data target --ui=ui --console=console
        header = header.copy
        LITTLE-ENDIAN.put-uint32 header 76 data.size
      out += header + data
  else:
    out = retarget input target --ui=ui --console=console
  return out

/**
Retargets the raw AP $image (its slots and anchor record) to the $target
  descriptor and returns the new image.
*/
retarget image/ByteArray target/Partitions --ui/cli.Ui --console/int?=null -> ByteArray:
  if image.size < 32 or (sha256 image[..image.size - 32]) != image[image.size - 32..]:
    ui.abort "AP image SHA-256 checksum mismatch"
  // Exclude the hash from every content bound: a truncated reservation
  // must not borrow its final bytes from the checksum trailer.
  image = image[..image.size - 32]
  if image.size > FLASH-END - 0x24000:
    ui.abort "AP image exceeds EC618 flash"
  input-record/AnchorRecord? := null
  error := catch: input-record = find-provisioning-anchor image
  if error: ui.abort "invalid AP anchor: $error"
  if input-record == null:
    ui.abort "no anchor record in the AP image — provision the default layout first (gen-anchor.toit)"
  input-entries := input-record.parts.entries
  anchor-file := input-record.parts["anchor"].offset - input-record.parts["base"].offset
  if console != null and console != ANCHOR-CONSOLE-OFF and not 0 <= console <= 2:
    ui.abort "console UART must be 0, 1, 2, or $ANCHOR-CONSOLE-OFF"

  input-base := first-of input-entries "base"
  input-slot := first-of input-entries "slot"
  input-anchor := first-of input-entries "anchor"
  if input-base == null or input-slot == null or input-anchor == null:
    ui.abort "the table embedded in the input image lacks base/slot/anchor entries"

  target-base := first-of target.entries "base"
  target-slot := first-of target.entries "slot"
  slots := target.entries.filter: it.type == "slot"

  // Guardrails: the frozen territory must not move, slot sizes must
  // match (the image is built for its reservation). Every fixed entry must
  // retain its name, type and geometry, including vendor and live-data regions.
  if target-base.offset != input-base.offset or target-base.size != input-base.size:
    ui.abort "the base partition cannot move (frozen contract)"
  if (target["anchor"].offset) != input-anchor.offset:
    ui.abort "the anchor cannot move without a base bump (it is the findable spot)"
  if target-slot.size != input-slot.size:
    ui.abort "slot size 0x$(%x target-slot.size) != image's 0x$(%x input-slot.size) — rebuild, don't retarget"
  input-entries.do: | p/Partition |
    if p.type != "slot" and p.type != "free":
      t := target.entries.filter: it.name == p.name
      if t.is-empty or t[0].type != p.type or t[0].offset != p.offset or t[0].size != p.size:
        ui.abort "refusing to move/resize/retype fixed partition '$p.name' ($p.type)"

  // Lift the slot-A reservation and read the merged relocation table at
  // its tail: [ table ][ size : last u32 ].
  src-file := input-slot.offset - input-base.offset
  slot-size := input-slot.size
  if src-file + slot-size > image.size:
    ui.abort "image ($image.size bytes) does not span the source slot reservation"
  content := src-file + slot-size
  if not (image[content..].every: it == 0xff):
    ui.abort "non-erased data after slot A: provisioning cannot discard a populated second slot or live data"
  slot-bytes := image.copy src-file (src-file + slot-size)
  table-length := LITTLE-ENDIAN.uint32 slot-bytes (slot-size - 4)
  if not (0 < table-length <= slot-size - 4):
    ui.abort "no merged relocation table at the source slot tail"
  merged/SlotRelocTable? := null
  error = catch:
    merged = SlotRelocTable.parse (slot-bytes.copy (slot-size - 4 - table-length) (slot-size - 4))
  if error: ui.abort "invalid source relocation table: $error"
  if merged.slot-size != slot-size:
    ui.abort "source relocation table slot size does not match the anchor reservation"
  tgt-file := target-slot.offset - target-base.offset
  prefix-end := min (tgt-file + slot-size) src-file
  if tgt-file < prefix-end and not (image[tgt-file..prefix-end].every: it == 0xff):
    ui.abort "target slot would overwrite non-erased data before source slot A"

  // Un-relocate the body to canonical, re-relocate to the target slot.
  // The .data init and the tail trailer are position-independent and ride
  // along verbatim.
  src-xip := input-slot.offset + target.xip-offset
  tgt-xip := target-slot.offset + target.xip-offset
  body := slot-bytes[.. merged.body-size]
  merged.apply body --base=0 --delta=(src-xip - merged.link-base) --direction=TO-CANONICAL
  merged.apply body --base=0 --delta=(tgt-xip - merged.link-base) --direction=TO-SLOT

  // Assemble: the image proper ends at the source slot-A reservation
  // (this tool handles single-populated-slot images; only verified erased
  // padding may follow). Erase the source reservation, place the retargeted
  // slot, normalize to the end of the LAST target slot reservation
  // (erased slot B), write the target record, and append a fresh trailer
  // for parity with what `firmware extract` emits.
  last-slot := slots.last
  normalized-size := last-slot.offset + last-slot.size - target-base.offset
  if content > normalized-size:
    ui.abort "target slot reservations end before the source slot-A image content"
  out := ByteArray normalized-size --initial=0xff
  out.replace 0 image[..content]
  out.fill --from=src-file --to=(src-file + slot-size) 0xff
  out.replace tgt-file slot-bytes
  // Known-good console: explicit override, else preserved from the input
  // image. This is static provisioning, not a live-device OTA transaction.
  effective-console := console or input-record.console
  out.replace anchor-file (encode-anchor-region target --console=effective-console)

  print "provision: slot A 0x$(%x input-slot.offset) -> 0x$(%x target-slot.offset)"
  return out + (sha256 out)
