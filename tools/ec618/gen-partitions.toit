// Copyright (C) 2026 Toit contributors.

// Generates the C constants header from the EC618 partition descriptor
// (toolchains/ec618/partitions.yaml — the single source of truth for the
// flash layout, docs/partition-table-design.md §0).
//
// The generated header is CHECKED IN so builds do not depend on running
// this tool; regenerate after every descriptor change (the header states
// the command). Parsing, offset derivation and validation live in
// tools/ec618/partitions.toit (shared with the other host tools); equal
// slot sizes emit a TOIT_PART_SLOT_SIZE convenience define.

import cli
import host.file
import host.pipe

import .partitions

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
  parts/Partitions? := null
  error := catch: parts = Partitions.load invocation["descriptor"]
  if error:
    pipe.print-to-stderr "gen-partitions: $error"
    exit 1

  slots := parts.entries.filter: it.type == "slot"
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
  out.add "#define TOIT_PART_XIP_OFFSET 0x$(%08x parts.xip-offset)u"
  out.add ""
  parts.entries.do: | p/Partition |
    c-name := p.name.to-ascii-upper.replace --all "-" "_"
    out.add "// $p.name ($p.type)"
    out.add "#define TOIT_PART_$(c-name)_OFFSET 0x$(%08x p.offset)u"
    out.add "#define TOIT_PART_$(c-name)_SIZE   0x$(%08x p.size)u"
    out.add "#define TOIT_PART_$(c-name)_XIP    (TOIT_PART_$(c-name)_OFFSET + TOIT_PART_XIP_OFFSET)"
    out.add ""
  if slots.size == 2 and slots[0].size == slots[1].size:
    out.add "// Both VM slots share one size."
    out.add "#define TOIT_PART_SLOT_SIZE 0x$(%08x slots[0].size)u"
    out.add ""

  file.write-contents --path=invocation["out"] (out.join "\n")
  print "gen-partitions: $(parts.entries.size) entries -> $invocation["out"]"
