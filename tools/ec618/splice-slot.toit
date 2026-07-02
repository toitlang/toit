// Copyright (C) 2026 Toit contributors.

// Splice a separately linked slot image into the base AP image (frozen-base
// phase 4, docs/frozen-base-phase4.md).
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
            --help="XIP address of the AP image's byte 0."
            --default="0x824000",
        cli.Option "out"
            --help="The output AP image."
            --required,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  base := file.read-contents invocation["base"]
  slot := file.read-contents invocation["slot-bin"]
  slot-address := parse-int invocation["slot-address"]
  ap-load-addr := parse-int invocation["ap-load-addr"]

  offset := slot-address - ap-load-addr
  if offset < 0 or offset + slot.size > base.size:
    pipe.print-to-stderr "slot [file 0x$(%x offset), +0x$(%x slot.size)) does not fit the base image ($base.size bytes)"
    exit 1

  out := base.copy
  out.replace offset slot
  file.write-contents --path=invocation["out"] out
  print "spliced 0x$(%x slot.size) slot bytes at file 0x$(%x offset) -> $invocation["out"]"

/** Parses an integer that may be hex (`0x`-prefixed) or decimal. */
parse-int s/string -> int:
  if s.starts-with "0x" or s.starts-with "0X":
    return int.parse s[2..] --radix=16
  return int.parse s
