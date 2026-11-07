// Copyright (C) 2026 Toit contributors.

import expect show *
import crypto.crc show Crc
import encoding.yaml
import host.file
import io show LITTLE-ENDIAN
import .partitions

checksum record/ByteArray -> ByteArray:
  record = record.copy
  count := record[10] + record[11]
  end := ANCHOR-HEADER-SIZE + count * ANCHOR-ENTRY-SIZE
  crc := Crc.little-endian 32 --polynomial=0xEDB88320 --initial-state=0xffff_ffff --xor-result=0xffff_ffff
  crc.add record[..end]
  LITTLE-ENDIAN.put-uint32 record end crc.get-as-int
  return record

image-with parts/Partitions first/ByteArray second/ByteArray?=null -> ByteArray:
  offset := parts["anchor"].offset - parts["base"].offset
  image := ByteArray (offset + 2 * SECTOR) --initial=0xff
  image.replace offset first
  if second: image.replace (offset + SECTOR) second
  return image

trial-record parts/Partitions trial/Partitions -> ByteArray:
  record := encode-anchor-record parts
  other := encode-anchor-record trial
  record = record[..record.size - ANCHOR-TRAILER-SIZE] +
      other[ANCHOR-HEADER-SIZE..other.size - ANCHOR-TRAILER-SIZE]
  record += ByteArray ANCHOR-TRAILER-SIZE --initial=0xff
  record[3] = 1
  LITTLE-ENDIAN.put-uint32 record 4 2
  record[9] = 'B'
  record[11] = trial.entries.size
  record[13] = 1
  return checksum record

expect-invalid parts/Partitions record/ByteArray message/string:
  error := catch: find-anchor-record (image-with parts (checksum record))
  expect (error is string and error.contains message)

main:
  parts := Partitions.load
  first := encode-anchor-record parts
  second := encode-anchor-record parts --console=1
  LITTLE-ENDIAN.put-uint32 second 4 2
  second = checksum second
  image := image-with parts first second
  expect-equals 1 (find-anchor-console image)
  expect-equals 2 (find-anchor-record image).seq
  // Higher sequence wins independently of sector ordering. Equal sequences
  // select the lower-address sector, including the uint32 limit.
  expect-equals 1 (find-anchor-console (image-with parts second first))
  LITTLE-ENDIAN.put-uint32 second 4 1
  expect-equals 0 (find-anchor-console (image-with parts first (checksum second)))
  LITTLE-ENDIAN.put-uint32 second 4 0xffff_ffff
  expect-equals 1 (find-anchor-console (image-with parts first (checksum second)))
  second = checksum second
  second[second.size - ANCHOR-TRAILER-SIZE] ^= 1
  expect-equals 0 (find-anchor-console (image-with parts first second))
  blank := ByteArray SECTOR --initial=0xff
  expect-equals null (find-anchor-table (image-with parts blank))
  expect-equals 0 (find-anchor-console (image-with parts blank first))
  // Reject bad header state even when the CRC matches it.
  [[2, 2], [3, 1], [8, 'C'], [9, 'A'], [9, 'B'], [12, 3]].do: |change/List|
    invalid := first.copy
    invalid[change[0]] = change[1]
    invalid = checksum invalid
    expect-equals null (find-anchor-table (image-with parts invalid))
    expect-equals 0 (find-anchor-console (image-with parts invalid first))
  [[10, 0], [10, 33], [11, 1], [11, 33]].do: |change/List|
    invalid := first.copy
    invalid[change[0]] = change[1]
    expect-equals null (find-anchor-table (image-with parts invalid))
  shifted := Partitions.load "tests/hw/ec618/partitions-shifted.yaml"
  trial := trial-record parts shifted
  parsed := find-anchor-record (image-with parts first trial)
  expect-equals 'A' parsed.active
  expect-equals 'B' parsed.pending
  expect-equals 1 parsed.state
  expect-equals parts["ota-a"].offset parsed.parts["ota-a"].offset
  expect-equals shifted["ota-a"].offset parsed.pending-parts["ota-a"].offset
  expect-equals 1 parsed.pending-console
  trial[3] = 2
  expect-equals 2 (find-anchor-record (image-with parts (checksum trial))).state
  [[3, 0], [3, 3], [9, 'A'], [9, 'C'], [13, 3]].do: |change/List|
    invalid := trial.copy
    invalid[change[0]] = change[1]
    expect-equals null (find-anchor-table (image-with parts (checksum invalid)))
  // Semantically invalid tables must not fall back to a stale table whose
  // header/CRC happens to be valid. Every mutation has a recalculated CRC.
  invalid := first.copy
  invalid[ANCHOR-HEADER-SIZE + 24] = 0xff
  expect-invalid parts invalid "unknown partition type"
  invalid = first.copy
  invalid[ANCHOR-HEADER-SIZE] = 0
  expect-invalid parts invalid "NUL-padded"
  invalid = first.copy
  invalid.fill --from=ANCHOR-HEADER-SIZE --to=(ANCHOR-HEADER-SIZE + 16) 'x'
  expect-invalid parts invalid "NUL-padded"
  invalid = first.copy
  invalid[ANCHOR-HEADER-SIZE + 15] = 1
  expect-invalid parts invalid "NUL-padded"
  invalid = first.copy
  invalid[ANCHOR-HEADER-SIZE] = 0xff
  expect-invalid parts invalid "valid UTF-8"
  invalid = first.copy
  invalid.replace (ANCHOR-HEADER-SIZE + ANCHOR-ENTRY-SIZE)
      first[ANCHOR-HEADER-SIZE..ANCHOR-HEADER-SIZE + 16]
  expect-invalid parts invalid "duplicate entry"
  invalid = first.copy
  LITTLE-ENDIAN.put-uint32 invalid (ANCHOR-HEADER-SIZE + 16) SECTOR
  expect-invalid parts invalid "gap or overlap"
  invalid = first.copy
  LITTLE-ENDIAN.put-uint32 invalid (ANCHOR-HEADER-SIZE + 20) 1
  expect-invalid parts invalid "not 4 KiB aligned"
  invalid = first.copy
  invalid[ANCHOR-HEADER-SIZE + 6 * ANCHOR-ENTRY-SIZE + 24] = TYPE-CODES["free"]
  expect-invalid parts invalid "exactly two VM slots"
  invalid = trial.copy
  invalid[ANCHOR-HEADER-SIZE + parts.entries.size * ANCHOR-ENTRY-SIZE + 24] = 0xff
  error := catch: find-anchor-record (image-with parts first (checksum invalid))
  expect (error is string and error.contains "unknown partition type")

  offset := parts["anchor"].offset - parts["base"].offset
  image = image-with parts blank
  image.replace 0 first
  expect-equals null (find-anchor-record image)
  image.replace offset first
  expect-equals offset (find-anchor-record image).offset
  // A record fits, but its declared two-sector region is truncated.
  image = image[..offset + first.size]
  expect-throw "AP image does not contain the complete anchor region": find-anchor-record image
  expect-equals null (find-anchor-record image[..image.size - 1])

  // Two different self-consistent anchor regions cannot both describe this AP.
  doc := yaml.decode (file.read-contents DEFAULT-DESCRIPTOR-PATH)
  doc["partitions"][4]["size"] += 2 * SECTOR
  doc["partitions"][6]["size"] -= SECTOR
  doc["partitions"][7]["size"] -= SECTOR
  other := Partitions.from-document doc
  image = image-with other (encode-anchor-record other)
  image.replace offset first
  expect-throw "multiple anchor regions in the AP image": find-anchor-record image
  expect-invalid parts (trial-record parts other) "trial table moves the anchor"
  doc = yaml.decode (file.read-contents DEFAULT-DESCRIPTOR-PATH)
  doc["partitions"][2]["size"] += SECTOR
  doc["partitions"][4]["size"] -= SECTOR
  other = Partitions.from-document doc
  expect-invalid parts (trial-record parts other) "trial table changes the frozen base"
  print "EC618 anchor validation: newest record, headers, tables, location and trial state PASS"
