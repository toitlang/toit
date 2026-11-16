// Copyright (C) 2026 Toit contributors.

import expect show *
import io show Buffer LITTLE-ENDIAN
import .slot-reloc

table --body/int=0x100 --slot/int=0x1000 --data/int=0
    --abs32/List=[] --branches/List=[] --straddle/List=[] -> ByteArray:
  return (SlotRelocTable
      --link-base=0x991000
      --slot-size=slot
      --body-size=body
      --data-size=data
      --abs32-offsets=abs32
      --thmbl-offsets=branches
      --straddle-entries=straddle).to-bytes

main:
  valid := table --abs32=[0, 4, 252] --branches=[10, 14] --straddle=[[22, #[0, 0, 0, 0]]]
  parsed := SlotRelocTable.parse valid
  expect-equals valid parsed.to-bytes
  expect-equals 0xffff_ffff (read-varint #[0xff, 0xff, 0xff, 0xff, 0x0f] 0)[0]
  expect-equals 0 (read-varint #[0x80, 0] 0)[0]
  [
    table --abs32=[256],
    table --abs32=[2],
    table --branches=[3],
    table --abs32=[4, 4],
    table --branches=[4, 6],
    table --straddle=[[256, #[0, 0, 0, 0]]],
    table --straddle=[[3, #[0, 0, 0, 0]]],
  ].do: |blob/ByteArray|
    expect-throw "invalid SRL3 relocation site": SlotRelocTable.parse blob
  [
    table --abs32=[4] --branches=[6],
    table --abs32=[4] --straddle=[[6, #[0, 0, 0, 0]]],
    table --branches=[4] --straddle=[[6, #[0, 0, 0, 0]]],
  ].do: |blob/ByteArray|
    expect-throw "overlapping SRL3 relocation sites": SlotRelocTable.parse blob
  [
    table --body=0xffff_ffff,
    table --data=0xffff_ffff,
    table --body=0xfe0,
    table --slot=0 --body=0,
  ].do: |blob/ByteArray|
    expect-throw "SRL3 body/data overlaps the relocation trailer": SlotRelocTable.parse blob
  blob := table --straddle=[[6, #[0, 0, 0, 0]]]
  expect-throw "truncated SRL3 straddle bytes": SlotRelocTable.parse blob[..blob.size - 1]
  header := (table --abs32=[0])[..52]
  [#[0x80, 0x80, 0x80, 0x80, 0x10], #[0x80, 0x80, 0x80, 0x80, 0x80, 0]].do: |bytes/ByteArray|
    expect-throw "SRL3 varint exceeds uint32": SlotRelocTable.parse (header + bytes)
  expect-throw "truncated SRL3 varint": SlotRelocTable.parse (header + #[0x80])
  // Force offset accumulation past uint32 without asking the writer to
  // generate a negative delta. Both decoders must reject the site.
  header = header.copy
  LITTLE-ENDIAN.put-uint32 header 16 2
  expect-throw "invalid SRL3 relocation site":
    SlotRelocTable.parse (header + #[4, 0xfc, 0xff, 0xff, 0xff, 0x0f])
  blob = (table --abs32=[0]) + #[0, 0, 0]
  SlotRelocTable.parse blob
  expect-throw "invalid SRL3 trailing padding": SlotRelocTable.parse (blob + #[0, 0, 0, 0])
  blob[blob.size - 1] = 1
  expect-throw "invalid SRL3 trailing padding": SlotRelocTable.parse blob
  [-1, 0x1_0000_0000].do: |value/int|
    expect-throw "SRL3 varint exceeds uint32": write-varint (Buffer) value
  print "SRL3 host validation: geometry, sites, overlaps, varints and padding PASS"
