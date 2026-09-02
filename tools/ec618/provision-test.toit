// Copyright (C) 2026 Toit contributors.

import cli
import host.file

import .partitions
import .provision

main args:
  if args.size != 1:
    throw "Usage: provision-test.toit <canonical.binpkg>"

  compact := file.read-contents args[0]
  default-layout := Partitions.load "toolchains/ec618/partitions.yaml"
  shifted-layout := Partitions.load "tests/hw/ec618/partitions-shifted.yaml"
  ui := cli.Ui.plain --level=cli.Ui.SILENT-LEVEL

  normalized-default := retarget-container compact default-layout --ui=ui
  slots := default-layout.entries.filter: it.type == "slot"
  check (not slots.is-empty) "default descriptor has no slot"
  slot-size := slots.first.size
  check
      normalized-default.size == compact.size + slot-size
      "normalizing the compact image did not add exactly one erased slot"
  normalized-again := retarget-container normalized-default default-layout --ui=ui
  check normalized-again == normalized-default "normalization is not idempotent"

  shifted := retarget-container compact shifted-layout --ui=ui
  shifted-from-normalized := retarget-container normalized-default shifted-layout --ui=ui
  check shifted == shifted-from-normalized "compact and normalized inputs produced different shifted images"
  round-trip := retarget-container shifted default-layout --ui=ui
  check round-trip == normalized-default "normalized default -> shifted -> default round-trip changed bytes"

  print "provision-test: PASS"

check condition/bool message/string -> none:
  if not condition: throw message
