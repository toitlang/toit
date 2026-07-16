// Copyright (C) 2026 Toit contributors.

// Emits the anchor record region (two flash sectors) from the partition
// descriptor: sector 0 carries the provisioning record — boot state
// { active='A', pending=0, state=NONE, seq=1 } plus the full partition
// table — and sector 1 is left erased (0xff, the ping-pong partner).
// Spliced into the flashable AP image (Makefile), this is what makes a
// fresh flash bootable: the dispatcher refuses to boot without a valid
// record, by design (docs/partition-table-design.md §0.1).
//
// The on-flash format mirrors toolchains/ec618/project/inc/anchor.h:
//   header  16B  { magic 'T','A', version=2, state, seq u32, active,
//                  pending, table_count, reserved[5] }
//   entries 32B  { name[16] NUL-padded, offset u32, size u32, type,
//                  reserved[7] }
//   trailer 16B  { crc32 over header+entries, 12 x 0xff }

import cli
import crypto.crc show Crc
import host.file
import host.pipe
import io show LITTLE-ENDIAN

import .partitions

MAGIC ::= 0x4154  // Reads as 'T','A' on flash (little-endian).
VERSION ::= 2
SECTOR ::= 0x1000
HEADER-SIZE ::= 16
ENTRY-SIZE ::= 32
TRAILER-SIZE ::= 16
// Mirrors ANCHOR_MAX_ENTRIES in anchor.h — the device-side staging cap.
MAX-ENTRIES ::= 32

main args:
  cmd := cli.Command "gen-anchor"
      --help="""
        Emits the anchor record region (two sectors: the provisioning
        record + the erased ping-pong sector) from the partition
        descriptor.
        """
      --options=[
        cli.Option "out"
            --help="The output file (both sectors, 8 KiB)."
            --required,
        cli.Option "splice"
            --help="AP image(s) to patch in place at the descriptor's anchor offset (repeatable)."
            --multi,
        partitions-option,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  parts/Partitions? := null
  error := catch: parts = Partitions.load invocation["partitions"]
  if error:
    pipe.print-to-stderr "gen-anchor: $error"
    exit 1

  entries := parts.entries
  if entries.size > MAX-ENTRIES:
    pipe.print-to-stderr "gen-anchor: $entries.size entries exceed the device cap of $MAX-ENTRIES"
    exit 1

  record-size := HEADER-SIZE + entries.size * ENTRY-SIZE + TRAILER-SIZE
  record := ByteArray record-size  // Zero-filled: reserved fields stay 0.
  LITTLE-ENDIAN.put-uint16 record 0 MAGIC
  record[2] = VERSION
  record[3] = 0    // SLOT_STATE_NONE: no trial in progress.
  LITTLE-ENDIAN.put-uint32 record 4 1  // seq = 1.
  record[8] = 'A'  // Known-good slot.
  record[9] = 0    // No pending trial.
  record[10] = entries.size
  offset := HEADER-SIZE
  entries.do: | p/Partition |
    record.replace offset p.name.to-byte-array
    LITTLE-ENDIAN.put-uint32 record (offset + 16) p.offset
    LITTLE-ENDIAN.put-uint32 record (offset + 20) p.size
    record[offset + 24] = TYPE-CODES[p.type]
    offset += ENTRY-SIZE

  // Standard CRC-32, as anchor.c computes it; the 12 pad bytes after it
  // are 0xff like erased flash.
  crc := Crc.little-endian 32 --polynomial=0xEDB88320 --initial-state=0xffff_ffff --xor-result=0xffff_ffff
  crc.add record[..record-size - TRAILER-SIZE]
  LITTLE-ENDIAN.put-uint32 record (record-size - TRAILER-SIZE) crc.get-as-int
  record.fill --from=(record-size - TRAILER-SIZE + 4) 0xff

  region := ByteArray (2 * SECTOR) --initial=0xff
  region.replace 0 record
  file.write-contents --path=invocation["out"] region
  print "gen-anchor: $entries.size entries, record $record-size bytes -> $invocation["out"]"

  // The AP image's byte 0 is the base partition's first byte, so the
  // anchor region sits at a descriptor-derived file offset.
  file-offset := (parts["anchor"].offset) - (parts["base"].offset)
  invocation["splice"].do: | path/string |
    image := file.read-contents path
    if file-offset + region.size > image.size:
      pipe.print-to-stderr "gen-anchor: $path ($image.size bytes) does not reach the anchor region (file 0x$(%x file-offset))"
      exit 1
    patched := image.copy
    patched.replace file-offset region
    file.write-contents --path=path patched
    print "gen-anchor: spliced at file 0x$(%x file-offset) -> $path"
