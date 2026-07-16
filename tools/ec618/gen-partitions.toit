// Copyright (C) 2026 Toit contributors.

// Generates the C constants header from the EC618 partition descriptor
// (toolchains/ec618/partitions.yaml — the single source of truth for the
// flash layout, docs/partition-table-design.md §0).
//
// The generated header is CHECKED IN so builds do not depend on running
// this tool; regenerate after every descriptor change (the header states
// the command). Validation: entries must be sorted, 4 KiB aligned,
// gap-free and cover exactly 0x000000..0x400000; equal slot sizes emit a
// TOIT_PART_SLOT_SIZE convenience define.

import cli
import encoding.yaml
import host.file
import host.pipe

FLASH-END ::= 0x40_0000
SECTOR ::= 0x1000

main args:
  cmd := cli.Command "gen-partitions"
      --help="Generates toit_partitions.h from the partition descriptor."
      --options=[
        cli.Option "out"
            --help="The header file to write."
            --required,
      ]
      --rest=[
        cli.Option "descriptor"
            --help="The partitions.yaml descriptor."
            --required,
      ]
      --run=:: run it
  cmd.run args

run invocation/cli.Invocation -> none:
  descriptor-path := invocation["descriptor"]
  doc := yaml.decode (file.read-contents descriptor-path)
  xip-offset := doc["xip-offset"]
  partitions := doc["partitions"]

  // Validate: sorted, aligned, contiguous, full coverage.
  cursor := 0
  partitions.do: | p/Map |
    name := p["name"]
    offset := p["offset"]
    size := p["size"]
    if offset != cursor:
      fail "$name: starts at 0x$(%x offset), expected 0x$(%x cursor) (gap or overlap)"
    if offset % SECTOR != 0 or size % SECTOR != 0:
      fail "$name: offset/size not 4 KiB aligned"
    if size <= 0: fail "$name: empty"
    cursor = offset + size
  if cursor != FLASH-END:
    fail "table covers 0x$(%x cursor), expected 0x$(%x FLASH-END)"

  slot-sizes := partitions.filter: it["type"] == "slot"
  out := []
  out.add "// GENERATED FILE — DO NOT EDIT."
  out.add "// Source of truth: toolchains/ec618/partitions.yaml. Regenerate with:"
  out.add "//   build/host/sdk/bin/toit tools/ec618/gen-partitions.toit \\"
  out.add "//       --out toolchains/ec618/project/inc/toit_partitions.h \\"
  out.add "//       toolchains/ec618/partitions.yaml"
  out.add "//"
  out.add "// Offsets are RAW flash addresses; _XIP adds the memory-mapped view."
  out.add "#pragma once"
  out.add ""
  out.add "#define TOIT_PART_XIP_OFFSET 0x$(%08x xip-offset)u"
  out.add ""
  partitions.do: | p/Map |
    c-name := p["name"].to-ascii-upper.replace --all "-" "_"
    out.add "// $(p["name"]) ($(p["type"]))"
    out.add "#define TOIT_PART_$(c-name)_OFFSET 0x$(%08x p["offset"])u"
    out.add "#define TOIT_PART_$(c-name)_SIZE   0x$(%08x p["size"])u"
    out.add "#define TOIT_PART_$(c-name)_XIP    (TOIT_PART_$(c-name)_OFFSET + TOIT_PART_XIP_OFFSET)"
    out.add ""
  if slot-sizes.size == 2 and slot-sizes[0]["size"] == slot-sizes[1]["size"]:
    out.add "// Both VM slots share one size."
    out.add "#define TOIT_PART_SLOT_SIZE 0x$(%08x slot-sizes[0]["size"])u"
    out.add ""

  file.write-contents --path=invocation["out"] (out.join "\n")
  print "gen-partitions: $(partitions.size) entries -> $invocation["out"]"

fail message/string -> none:
  pipe.print-to-stderr "gen-partitions: $message"
  exit 1
