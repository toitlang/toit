// Copyright (C) 2026 Toit contributors.

import cli
import cli.test show TestUi TestAbort
import crypto.sha256 show sha256
import host.file
import io show LITTLE-ENDIAN
import encoding.yaml

import .partitions
import .provision
import .anchor-test show checksum trial-record

main args:
  if args.size != 1:
    throw "Usage: provision-test.toit <canonical.binpkg>"

  compact := file.read-contents args[0]
  default-layout := Partitions.load "toolchains/ec618/partitions.yaml"
  shifted-layout := Partitions.load "tests/hw/ec618/partitions-shifted.yaml"
  ui := cli.Ui.plain --level=cli.Ui.SILENT-LEVEL

  normalized-default := retarget-container compact default-layout --ui=ui
  slots := default-layout.entries.filter: it.type == "slot"
  check (not slots.is-empty) "default descriptor has no slot"
  slot-size := slots.first.size
  check
      normalized-default.size == compact.size + slot-size
      "normalizing the compact image did not add exactly one erased slot"
  normalized-again := retarget-container normalized-default default-layout --ui=ui
  check normalized-again == normalized-default "normalization is not idempotent"

  shifted := retarget-container compact shifted-layout --ui=ui
  shifted-from-normalized := retarget-container normalized-default shifted-layout --ui=ui
  check shifted == shifted-from-normalized "compact and normalized inputs produced different shifted images"
  round-trip := retarget-container shifted default-layout --ui=ui
  check round-trip == normalized-default "normalized default -> shifted -> default round-trip changed bytes"

  test-malformed-containers compact default-layout
  test-fixed-partitions compact
  test-ap-integrity compact default-layout
  test-anchor-input compact default-layout
  test-source-reservation compact default-layout shifted-layout

  print "provision-test: PASS"

check condition/bool message/string -> none:
  if not condition: throw message

test-malformed-containers compact/ByteArray target/Partitions:
  original := compact.copy
  ap-start := BINPKG-HEADER-SIZE
  ap-size := LITTLE-ENDIAN.uint32 compact (ap-start + 76)
  ap-end := ap-start + ZONE-HEADER-SIZE + ap-size
  ap-zone := compact[ap-start..ap-end]
  ap-only := compact[..ap-end]
  cp-zones := compact[ap-end..]
  check (not cp-zones.is-empty) "test image must include CP to verify preservation"
  ui := cli.Ui.plain --level=cli.Ui.SILENT-LEVEL
  converted := retarget-container compact target --ui=ui
  new-ap-end := BINPKG-HEADER-SIZE + ZONE-HEADER-SIZE +
      (LITTLE-ENDIAN.uint32 converted (BINPKG-HEADER-SIZE + 76))
  check converted[new-ap-end..] == cp-zones "retarget changed a non-AP zone"
  converted-ap := retarget-container ap-only target --ui=ui
  check converted-ap == converted[..new-ap-end] "AP-only container retarget differs"
  reordered := (ByteArray BINPKG-HEADER-SIZE) + cp-zones + ap-zone
  converted-reordered := retarget-container reordered target --ui=ui
  check converted-reordered == (ByteArray BINPKG-HEADER-SIZE) + cp-zones + converted-ap[BINPKG-HEADER-SIZE..]
      "retarget changed zone ordering or contents when AP was not first"
  raw := retarget-container compact[ap-start + ZONE-HEADER-SIZE..ap-end] target --ui=ui
  check raw == converted-ap[BINPKG-HEADER-SIZE + ZONE-HEADER-SIZE..] "raw AP retarget differs"

  [1, 100, ZONE-HEADER-SIZE - 1].do: |size/int|
    expect-rejected (compact + (ByteArray size)) target "truncated binpkg zone header"
  expect-rejected (compact[..compact.size - 1]) target "truncated binpkg zone data"
  expect-rejected (ap-only[..ap-only.size - 1]) target "truncated binpkg zone data"
  expect-rejected (ByteArray BINPKG-HEADER-SIZE) target "no AP zone in the binpkg"
  expect-rejected ((ByteArray BINPKG-HEADER-SIZE) + cp-zones) target "no AP zone in the binpkg"
  expect-rejected (compact[..BINPKG-HEADER-SIZE + 1]) target "truncated binpkg zone header"
  oversized := compact.copy
  LITTLE-ENDIAN.put-uint32 oversized (BINPKG-HEADER-SIZE + 76) 0xffff_ffff
  expect-rejected oversized target "truncated binpkg zone data"
  expect-rejected (ap-only + ap-zone) target "multiple AP zones in the binpkg"
  wrong-subsystem := ap-only.copy
  wrong-subsystem[BINPKG-HEADER-SIZE + 338] = 'X'
  expect-rejected wrong-subsystem target "no AP zone in the binpkg"
  corrupt := compact.copy
  corrupt[BINPKG-HEADER-SIZE + ZONE-HEADER-SIZE] ^= 1
  expect-rejected corrupt target "AP image SHA-256 checksum mismatch"
  corrupt = compact.copy
  corrupt[ap-end - 1] ^= 1
  expect-rejected corrupt target "AP image SHA-256 checksum mismatch"
  empty-ap := compact[..BINPKG-HEADER-SIZE + ZONE-HEADER-SIZE].copy
  LITTLE-ENDIAN.put-uint32 empty-ap (BINPKG-HEADER-SIZE + 76) 0
  expect-rejected empty-ap target "AP image SHA-256 checksum mismatch"
  check original == compact "retarget mutated its input buffer"

expect-rejected input/ByteArray target/Partitions message/string:
  ui := TestUi
  error := catch: retarget-container input target --ui=ui
  check (error is TestAbort) "expected a CLI error for '$message', got $error"
  output := ui.stdout + ui.stderr
  check (output.contains message) "expected '$message', got $output"

test-fixed-partitions input/ByteArray:
  // These edits retain full flash coverage and the same slot/base/anchor
  // geometry. They must still be refused when retargeting an existing base.
  doc := yaml.decode (file.read-contents DEFAULT-DESCRIPTOR-PATH)
  doc["partitions"][4]["type"] = "data"
  expect-rejected input (Partitions.from-document doc) "fixed partition 'littlefs'"
  doc = yaml.decode (file.read-contents DEFAULT-DESCRIPTOR-PATH)
  doc["partitions"][10]["name"] = "renamed-cal"
  expect-rejected input (Partitions.from-document doc) "fixed partition 'nvram-factory'"
  doc = yaml.decode (file.read-contents DEFAULT-DESCRIPTOR-PATH)
  doc["partitions"][10]["size"] -= SECTOR
  doc["partitions"][11]["size"] += SECTOR
  expect-rejected input (Partitions.from-document doc) "fixed partition 'nvram-factory'"
  doc = yaml.decode (file.read-contents DEFAULT-DESCRIPTOR-PATH)
  doc["partitions"][4]["name"] = "renamed-store"
  expect-rejected input (Partitions.from-document doc) "fixed partition 'littlefs'"

test-ap-integrity input/ByteArray target/Partitions:
  ap-start := BINPKG-HEADER-SIZE + ZONE-HEADER-SIZE
  ap-size := LITTLE-ENDIAN.uint32 input (BINPKG-HEADER-SIZE + 76)
  ap := input[ap-start..ap-start + ap-size]
  original := ap.copy
  corrupt := ap.copy
  corrupt[0] ^= 1
  expect-rejected corrupt target "AP image SHA-256 checksum mismatch"
  corrupt = ap.copy
  corrupt[corrupt.size - 1] ^= 1
  expect-rejected corrupt target "AP image SHA-256 checksum mismatch"
  expect-rejected (ap[..ap.size - 32]) target "AP image SHA-256 checksum mismatch"
  expect-rejected (ap[..ap.size - 1]) target "AP image SHA-256 checksum mismatch"
  expect-rejected (ap + #[0xff]) target "AP image SHA-256 checksum mismatch"
  [0, 1, 31, 32].do: |size/int|
    expect-rejected (ByteArray size --initial=0xff) target "AP image SHA-256 checksum mismatch"

  ui := cli.Ui.plain --level=cli.Ui.SILENT-LEVEL
  normalized := retarget-container ap target --ui=ui
  body := normalized[..normalized.size - 32].copy
  slots := target.entries.filter: it.type == "slot"
  slot-a-end := slots.first.offset + slots.first.size - target["base"].offset
  slot-b-start := slots.last.offset - target["base"].offset
  // An otherwise valid checksum must not authorize discarding a second
  // populated slot, data after the slots, or unexplained bytes in the gap.
  [slot-a-end, slot-b-start + 123, body.size - 1].do: |offset/int|
    populated := body.copy
    populated[offset] = 0
    expect-rejected (populated + (sha256 populated)) target "non-erased data after slot A"
  populated := body + #[0]
  expect-rejected (populated + (sha256 populated)) target "non-erased data after slot A"
  padded := ByteArray (FLASH-END - target["base"].offset) --initial=0xff
  padded.replace 0 body
  check (retarget-container (padded + (sha256 padded)) target --ui=ui) == normalized
      "erased AP padding changed the normalized image"
  too-long := ByteArray (FLASH-END - target["base"].offset + 1) --initial=0xff
  too-long.replace 0 body
  expect-rejected (too-long + (sha256 too-long)) target "AP image exceeds EC618 flash"
  // The checksum bytes do not count toward the source slot reservation.
  short-body := ap[..ap.size - 32 - 1]
  expect-rejected (short-body + (sha256 short-body)) target "does not span the source slot reservation"

  // The same populated-slot rejection must apply inside binpkg input.
  body[slot-b-start] = 0
  populated = body + (sha256 body)
  header := input[BINPKG-HEADER-SIZE..ap-start].copy
  LITTLE-ENDIAN.put-uint32 header 76 populated.size
  expect-rejected ((ByteArray BINPKG-HEADER-SIZE) + header + populated) target "non-erased data after slot A"
  check ap == original "AP validation mutated its input"

test-anchor-input input/ByteArray target/Partitions:
  ap-start := BINPKG-HEADER-SIZE + ZONE-HEADER-SIZE
  ap-size := LITTLE-ENDIAN.uint32 input (BINPKG-HEADER-SIZE + 76)
  ap := input[ap-start..ap-start + ap-size]
  initial := encode-anchor-record target
  changed := initial.copy
  changed[8] = 'B'
  reject-anchor ap target (checksum changed) "initial provisioning anchor"
  changed = initial.copy
  LITTLE-ENDIAN.put-uint32 changed 4 2
  changed = checksum changed
  reject-anchor ap target changed "initial provisioning anchor"
  reject-anchor ap target initial "initial provisioning anchor" --second=changed
  reject-anchor ap target (trial-record target target) "initial provisioning anchor"
  // Even an invalid/torn partner must not be erased silently by a static
  // reprovision: the caller needs a fresh build artifact, not a device dump.
  reject-anchor ap target initial "initial provisioning anchor" --second=#[0]
  changed = initial.copy
  changed[ANCHOR-HEADER-SIZE + 24] = 0xff
  reject-anchor ap target (checksum changed) "invalid AP anchor:"
  changed = initial.copy
  LITTLE-ENDIAN.put-uint32 changed (ANCHOR-HEADER-SIZE + 16) SECTOR
  reject-anchor ap target (checksum changed) "invalid AP anchor:"
  changed = initial.copy
  changed[12] = 3
  reject-anchor ap target (checksum changed) "no anchor record"
  [-1, 3, 256].do: |console/int|
    ui := TestUi
    error := catch: retarget-container ap target --ui=ui --console=console
    check (error is TestAbort) "invalid console did not produce a CLI error"
    check ((ui.stdout + ui.stderr).contains "console UART must be") "invalid console diagnostic"
  // Static console overrides remain supported, including UART0 and off.
  ui := cli.Ui.plain --level=cli.Ui.SILENT-LEVEL
  [0, 1, 2, ANCHOR-CONSOLE-OFF].do: |console/int|
    converted := retarget-container ap target --ui=ui --console=console
    check (find-anchor-console converted) == console "console override was lost"
    again := retarget-container converted target --ui=ui
    check converted == again "static console not preserved on reprovision"

reject-anchor ap/ByteArray parts/Partitions record/ByteArray message/string --second/ByteArray?=null:
  body := ap[..ap.size - 32].copy
  offset := parts["anchor"].offset - parts["base"].offset
  body.fill --from=offset --to=(offset + 2 * SECTOR) 0xff
  body.replace offset record
  if second: body.replace (offset + SECTOR) second
  expect-rejected (body + (sha256 body)) parts message

test-source-reservation input/ByteArray normal/Partitions shifted/Partitions:
  ap-start := BINPKG-HEADER-SIZE + ZONE-HEADER-SIZE
  ap-size := LITTLE-ENDIAN.uint32 input (BINPKG-HEADER-SIZE + 76)
  ap := input[ap-start..ap-start + ap-size]
  ui := cli.Ui.plain --level=cli.Ui.SILENT-LEVEL
  shifted-ap := retarget-container ap shifted --ui=ui
  body := shifted-ap[..shifted-ap.size - 32].copy
  // Shifting back must not overwrite unexpected contents in the free pad
  // immediately before the source slot, even with a valid AP checksum.
  pad := shifted["shift-pad"].offset - shifted["base"].offset
  body[pad] = 0
  expect-rejected (body + (sha256 body)) normal "target slot would overwrite non-erased data"
  // Keeping that pad outside the destination slot preserves its contents.
  unchanged := retarget-container (body + (sha256 body)) shifted --ui=ui
  check unchanged[pad] == 0 "retarget discarded unaffected free-space contents"

  body = ap[..ap.size - 32].copy
  slot := normal["ota-a"]
  end := slot.offset - normal["base"].offset + slot.size
  length := LITTLE-ENDIAN.uint32 body (end - 4)
  table := end - 4 - length
  LITTLE-ENDIAN.put-uint32 body (table + 8) (slot.size + SECTOR)
  expect-rejected (body + (sha256 body)) normal "source relocation table slot size does not match"
  body = ap[..ap.size - 32].copy
  body[table] ^= 1
  expect-rejected (body + (sha256 body)) normal "invalid source relocation table:"
