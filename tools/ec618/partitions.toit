// Copyright (C) 2026 Toit contributors.

// Shared loader for the EC618 partition descriptor
// (toolchains/ec618/partitions.yaml — the single source of truth for the
// flash layout, docs/partition-table-design.md §0).
//
// Entries may omit `offset`: it is then derived as the end of the previous
// entry. This is how the anchor chain stays soft — base-id starts wherever
// the base ends, the slots wherever base-id ends — so a future base-size
// change is a one-line `size:` edit, not a cascade of address edits. An
// explicit `offset` is an EXTERNAL constraint (boot-ROM, SDK or live-data
// address) and doubles as an assertion: the derivation must land the chain
// exactly there, or loading fails.

import cli
import encoding.yaml
import host.file

DEFAULT-DESCRIPTOR-PATH ::= "toolchains/ec618/partitions.yaml"
FLASH-END ::= 0x40_0000
SECTOR ::= 0x1000

/**
Returns the shared --partitions option for host tools that read the
  descriptor. The default path is relative to the repository root, where
  the Makefile runs the tools.
*/
partitions-option -> cli.Option:
  return cli.Option "partitions"
      --help="The partition descriptor (partitions.yaml)."
      --default=DEFAULT-DESCRIPTOR-PATH

class Partition:
  name/string
  type/string
  offset/int
  size/int

  constructor .name .type .offset .size:

class Partitions:
  xip-offset/int
  entries/List  // Of $Partition, in flash order.
  by-name_/Map

  /**
  Loads and validates the descriptor at $path.

  Throws with a readable message on a missing file, a gap/overlap, a
    misaligned entry, or incomplete coverage of the flash.
  */
  constructor.load path/string=DEFAULT-DESCRIPTOR-PATH:
    if not file.is-file path:
      throw "partition descriptor not found at '$path' (run from the repo root or pass --partitions)"
    doc := yaml.decode (file.read-contents path)
    xip-offset = doc["xip-offset"]
    entries = []
    by-name_ = {:}
    cursor := 0
    doc["partitions"].do: | p/Map |
      name := p["name"]
      size := p["size"]
      offset := p.get "offset" --if-absent=: cursor
      if offset != cursor:
        throw "$name: starts at 0x$(%x offset), expected 0x$(%x cursor) (gap or overlap)"
      if offset % SECTOR != 0 or size % SECTOR != 0:
        throw "$name: offset/size not 4 KiB aligned"
      if size <= 0:
        throw "$name: empty"
      if by-name_.contains name:
        throw "$name: duplicate entry"
      entry := Partition name p["type"] offset size
      entries.add entry
      by-name_[name] = entry
      cursor = offset + size
    if cursor != FLASH-END:
      throw "table covers 0x$(%x cursor), expected 0x$(%x FLASH-END)"

  /** Returns the entry called $name; throws if there is none. */
  operator [] name/string -> Partition:
    return by-name_.get name --if-absent=: throw "no partition '$name' in the descriptor"

  /** Returns the XIP (memory-mapped) address of the partition called $name. */
  xip name/string -> int:
    return this[name].offset + xip-offset
