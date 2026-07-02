// Copyright (C) 2026 Toit contributors.

// Build a flashable dual-slot EC618 AP image from a single linked image.
//
// Replaces tools/splice_dual_slot.py: instead of byte-splicing a second
// (slot-B) link pass, this relocates the slot-A image to slot B using the
// SRL2 relocation table — the same relocate-on-write the device does for OTA.
// One link, one source image; slot B is produced by relocation.
//
// Input is the envelope-extracted AP binary (slot A populated, slot B
// reserved) plus the SRL2 table (build/ec618/slot-reloc.bin, used only for the
// slot geometry). The output has both slots populated and boots slot A by
// default (the slot marker reads as "no valid record" until the device stages
// a trial).
//
// The bundled extension now lives INSIDE the slot (after the VM body), and the
// MERGED relocation table — VM body + extension pointers — rides at the slot's
// tail (`[ table ][ size : last word ]`, written by tools/firmware.toit). So
// this tool relocates the WHOLE slot: it reads the merged table from slot A's
// tail, copies the entire slot A region into slot B, and applies the table.
// DromData.extension and the bundled container pointers are in-slot pointers,
// so the relocation shifts them into slot B too (option A).

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
            --help="The SRL2 relocation table (slot-reloc.bin)."
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
  geometry := SlotRelocTable.parse (file.read-contents invocation["reloc"])
  ap-load-addr := parse-int invocation["ap-load-addr"]

  link-base := geometry.link-base
  slot-size := geometry.slot-size
  slot-a-file := link-base - ap-load-addr
  slot-b-file := link-base + slot-size - ap-load-addr

  if slot-b-file + slot-size > ap-a.size:
    pipe.print-to-stderr "input too small: slot B region [0x$(%x slot-b-file), +0x$(%x slot-size)) exceeds the $(ap-a.size)-byte image"
    exit 1

  // The merged relocation table (VM body + in-slot extension pointers) rides
  // at slot A's tail: the slot's last word is the table size, the table the
  // bytes before it. Read it back to drive the relocation.
  size-word-pos := slot-a-file + slot-size - 4
  table-size := LITTLE-ENDIAN.uint32 ap-a size-word-pos
  if table-size <= 0 or table-size > slot-size:
    pipe.print-to-stderr "slot A has no in-slot relocation trailer (table size 0x$(%x table-size)); was the envelope built with --reloc.bin?"
    exit 1
  table := SlotRelocTable.parse (ap-a.copy (size-word-pos - table-size) size-word-pos)
  if table.link-base != link-base or table.slot-size != slot-size:
    pipe.print-to-stderr "slot A tail table geometry (0x$(%x table.link-base)/0x$(%x table.slot-size)) disagrees with $invocation["reloc"]"
    exit 1

  // Copy the WHOLE slot A region (VM body + extension + free + tail table) into
  // the reserved slot-B region, then relocate slot B's body+extension. The tail
  // table bytes are slot-independent (slot-relative offsets, link-base unchanged)
  // and lie beyond the populated front, so `apply` leaves them untouched.
  out := ap-a.copy
  out.replace slot-b-file ap-a slot-a-file (slot-a-file + slot-size)
  table.apply out --base=slot-b-file --delta=slot-size --direction=TO-SLOT

  // The two-sector slot marker sits right after slot B.
  active-slot/string? := invocation["active-slot"]
  if active-slot != null:
    if active-slot != "A" and active-slot != "B": throw "--active-slot must be A or B"
    marker-file := (link-base + 2 * slot-size) - ap-load-addr
    out.replace marker-file (marker-record active-slot[0])

  file.write-contents --path=invocation["out"] out

  print "Dual-slot image: slot A canonical, slot B relocated (+0x$(%x slot-size))."
  print "  slot A @ file 0x$(%x slot-a-file), slot B @ file 0x$(%x slot-b-file), populated 0x$(%x table.body-size)"
  print "  $table.abs32-offsets.size ABS32 + $table.thmbl-offsets.size branch reloc(s) applied (incl. in-slot extension)"
  if active-slot != null: print "  active-slot marker set to '$active-slot'"
  print "  -> $invocation["out"] ($out.size bytes)"

/**
Builds a 16-byte slot-marker record marking $active ('A'/'B') as known-good,
  no trial pending. Mirrors `slot_record` + `marker_crc32` in
  toolchains/ec618/project/src/slot_marker.c.
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
