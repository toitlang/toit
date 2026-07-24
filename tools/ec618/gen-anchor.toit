// Copyright (C) 2026 Toit contributors.

// Emits the anchor record region (two flash sectors) from the partition
// descriptor: sector 0 carries the provisioning record — boot state
// { active='A', pending=0, state=NONE, seq=1 } plus the full partition
// table — and sector 1 is left erased (0xff, the ping-pong partner).
// Spliced into the flashable AP image (Makefile), this is what makes a
// fresh flash bootable: the dispatcher refuses to boot without a valid
// record. The on-flash
// format lives in tools/ec618/partitions.toit (shared with provision.toit),
// mirroring toolchains/ec618/project/inc/anchor.h.

import cli
import host.file
import host.pipe

import .partitions

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
        cli.OptionInt "console-uart"
            --help="The console/control UART id for this device (0/1/2; 255 disables)."
            --default=0,
        partitions-option,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  parts/Partitions? := null
  region/ByteArray? := null
  error := catch:
    parts = Partitions.load invocation["partitions"]
    region = encode-anchor-region parts --console=invocation["console-uart"]
  if error:
    pipe.print-to-stderr "gen-anchor: $error"
    exit 1

  file.write-contents --path=invocation["out"] region
  print "gen-anchor: $parts.entries.size entries -> $invocation["out"]"

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
