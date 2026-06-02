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

  file.write-contents --path=invocation["out"] out

  print "Dual-slot image: slot A canonical, slot B relocated (+0x$(%x table.slot-size))."
  print "  slot A @ file 0x$(%x slot-a-file), slot B @ file 0x$(%x slot-b-file), body 0x$(%x body)"
  print "  $table.abs32-offsets.size ABS32 + $table.thmbl-offsets.size branch reloc(s) applied"
  print "  -> $invocation["out"] ($out.size bytes)"

/** Parses an integer that may be hex (`0x`-prefixed) or decimal. */
parse-int s/string -> int:
  if s.starts-with "0x" or s.starts-with "0X":
    return int.parse s[2..] --radix=16
  return int.parse s
