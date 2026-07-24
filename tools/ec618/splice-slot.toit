// Copyright (C) 2026 Toit contributors.

// Splice a separately linked slot image into the base AP image.
//
// The slot link (tools/ec618/gen-slot-ld.toit) confines all of its loadable
// bytes — body plus the .data init that rides after it — to the slot's flash
// region, so assembling the flashable/full AP image is a pure overlay: copy
// base.bin, write the slot bytes at the slot's file offset. The result has
// the exact shape of the old single-link ap.bin, so everything downstream
// (gen-slot-reloc, the gold check, the envelope, OTA) is unchanged.

import cli
import host.file
import host.pipe

import .partitions

main args:
  cmd := cli.Command "splice-slot"
      --help="""
        Overlays a slot link's binary onto the base AP image.
        """
      --options=[
        cli.Option "base"
            --help="The base AP image (build/ec618-base/base.bin)."
            --required,
        cli.Option "slot-bin"
            --help="The slot link's flat binary (objcopy -O binary of the slot elf)."
            --required,
        cli.Option "slot-address"
            --help="The slot's flash (XIP) address (hex or decimal)."
            --required,
        cli.Option "ap-load-addr"
            --help="XIP address of the AP image's byte 0 (default: the base XIP address from the partition descriptor).",
        partitions-option,
        cli.Option "out"
            --help="The output AP image."
            --required,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  parts := Partitions.load invocation["partitions"]
  base := file.read-contents invocation["base"]
  slot := file.read-contents invocation["slot-bin"]
  slot-address := parse-int invocation["slot-address"]
  ap-load-addr := invocation["ap-load-addr"]
      ? parse-int invocation["ap-load-addr"]
      : parts.xip "base"

  offset := slot-address - ap-load-addr
  if offset < 0:
    pipe.print-to-stderr "slot address 0x$(%x slot-address) is below the image base 0x$(%x ap-load-addr)"
    exit 1

  // The output must span the WHOLE slot reservation, not just the link's
  // bytes: downstream writes the reloc trailer at the reservation's tail.
  // The base link stops where its own sections end (the anchor sits below
  // the slots), so extend with 0xff — erased flash — up to the end of the
  // partition containing the slot.
  raw := slot-address - parts.xip-offset
  reservation-end := offset + slot.size
  parts.entries.do: | p/Partition |
    if p.offset <= raw and raw < p.offset + p.size:
      reservation-end = p.offset + p.size + parts.xip-offset - ap-load-addr
      if offset + slot.size > reservation-end:
        pipe.print-to-stderr "slot bytes [file 0x$(%x offset), +0x$(%x slot.size)) overflow the '$p.name' reservation (ends at file 0x$(%x reservation-end))"
        exit 1

  size := max base.size reservation-end
  out := ByteArray size --initial=0xff
  out.replace 0 base
  out.replace offset slot
  file.write-contents --path=invocation["out"] out
  print "spliced 0x$(%x slot.size) slot bytes at file 0x$(%x offset) -> $invocation["out"] ($size bytes)"

/** Parses an integer that may be hex (`0x`-prefixed) or decimal. */
parse-int s/string -> int:
  if s.starts-with "0x" or s.starts-with "0X":
    return int.parse s[2..] --radix=16
  return int.parse s
