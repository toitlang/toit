// Copyright (C) 2026 Toit contributors.

// Build a flashable dual-slot EC618 AP image from a single linked image.
//
// Replaces tools/splice_dual_slot.py: instead of byte-splicing a second
// (slot-B) link pass, this relocates the slot-A image to slot B using the
// SRL1 relocation table — the same relocate-on-write the device does for OTA.
// One link, one source image; slot B is produced by relocation.
//
// Input is the envelope-extracted AP binary (slot A populated, slot B
// reserved) plus the SRL1 table (build/ec618/slot-reloc.bin). The output has
// both slots populated and boots slot A by default (the slot marker reads as
// "no valid record" until the device stages a trial). DromData.extension is a
// fixed, out-of-slot address, so the relocation copies it verbatim into slot B
// — no DromData patching needed (unlike the splice).

import cli
import io show LITTLE-ENDIAN
import host.file
import host.pipe
import .slot-reloc

main args:
  cmd := cli.Command "build-dual-image"
      --help="""
        Relocate the slot-A image to slot B and write a dual-slot AP image.
        """
      --options=[
        cli.Option "slot-a"
            --help="The envelope-extracted slot-A AP binary."
            --required,
        cli.Option "reloc"
            --help="The SRL1 relocation table (slot-reloc.bin)."
            --required,
        cli.Option "ap-load-addr"
            --help="XIP address of ap.bin byte 0 (hex or decimal)."
            --default="0x824000",
        cli.Option "out"
            --help="The output dual-slot AP binary."
            --required,
        cli.Option "active-slot"
            --help="Pre-set the active-slot marker to 'A' or 'B' (default: leave it unset, which boots slot A)."
            --type="string",
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  ap-a := file.read-contents invocation["slot-a"]
  table := SlotRelocTable.parse (file.read-contents invocation["reloc"])
  ap-load-addr := parse-int invocation["ap-load-addr"]

  slot-a-file := table.link-base - ap-load-addr
  slot-b-file := table.link-base + table.slot-size - ap-load-addr
  body := table.body-size

  if slot-b-file + body > ap-a.size:
    pipe.print-to-stderr "input too small: slot B region [0x$(%x slot-b-file), +0x$(%x body)) exceeds the $(ap-a.size)-byte image"
    exit 1

  // Copy slot A into the (reserved) slot-B region, then relocate it there.
  out := ap-a.copy
  out.replace slot-b-file ap-a slot-a-file (slot-a-file + body)
  table.apply out --base=slot-b-file --delta=table.slot-size --direction=TO-SLOT

  // The two-sector slot marker sits right after slot B.
  active-slot/string? := invocation["active-slot"]
  if active-slot != null:
    if active-slot != "A" and active-slot != "B": throw "--active-slot must be A or B"
    marker-file := (table.link-base + 2 * table.slot-size) - ap-load-addr
    out.replace marker-file (marker-record active-slot[0])

  file.write-contents --path=invocation["out"] out

  print "Dual-slot image: slot A canonical, slot B relocated (+0x$(%x table.slot-size))."
  print "  slot A @ file 0x$(%x slot-a-file), slot B @ file 0x$(%x slot-b-file), body 0x$(%x body)"
  print "  $table.abs32-offsets.size ABS32 + $table.thmbl-offsets.size branch reloc(s) applied"
  if active-slot != null: print "  active-slot marker set to '$active-slot'"
  print "  -> $invocation["out"] ($out.size bytes)"

/**
Builds a 16-byte slot-marker record marking $active ('A'/'B') as known-good,
  no trial pending. Mirrors `slot_record` + `marker_crc32` in
  third_party/.../project/toit/src/slot_marker.c.
*/
marker-record active/int -> ByteArray:
  record := ByteArray 16
  LITTLE-ENDIAN.put-uint16 record 0 0x5453  // magic 'S','T'
  record[2] = 1        // version
  record[3] = 0        // state = SLOT_STATE_NONE
  LITTLE-ENDIAN.put-uint32 record 4 1  // seq = 1
  record[8] = active   // active slot
  record[9] = 0        // pending = none
  // reserved[10..11] stay 0.
  LITTLE-ENDIAN.put-uint32 record 12 (crc32 record 0 12)
  return record

/** Standard CRC-32 (poly 0xEDB88320) over `$bytes[$from..$to)`. */
crc32 bytes/ByteArray from/int to/int -> int:
  crc := 0xffffffff
  (to - from).repeat:
    crc ^= bytes[from + it]
    8.repeat:
      if (crc & 1) != 0: crc = (crc >> 1) ^ 0xedb88320
      else: crc = crc >> 1
  return (crc ^ 0xffffffff) & 0xffffffff

/** Parses an integer that may be hex (`0x`-prefixed) or decimal. */
parse-int s/string -> int:
  if s.starts-with "0x" or s.starts-with "0X":
    return int.parse s[2..] --radix=16
  return int.parse s
