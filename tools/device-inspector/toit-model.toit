// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import .target as target

/**
Describes how bytes and bytecode indices should be interpreted as Toit.

The metadata normally comes from the firmware and snapshot build artifacts.
It is independent of whether memory is read from a dump, GDB, or JTAG.
*/
class Interpretation:
  metadata/Map

  constructor input/Map:
    // Deliberately discard artifact and transport fields such as provenance,
    // register packets, payload offsets, and capture file format.
    metadata = {
      "target": input.get "target" --if-absent=: {:},
      "completeness": input.get "completeness" --if-absent=: {
        "semantic-coherence": false,
      },
      "program-layouts": input.get "program-layouts" --if-absent=: [],
    }
    if input.contains "runtime-layout":
      metadata["runtime-layout"] = input["runtime-layout"]
    if input.contains "inspector-description":
      metadata["inspector-description"] = input["inspector-description"]
    if input.contains "capture-scope":
      metadata["capture-scope"] = input["capture-scope"]

  runtime-layout -> Map?:
    return metadata.get "runtime-layout"

  inspector-description -> Map?:
    return metadata.get "inspector-description"

  program-layouts -> List:
    return metadata.get "program-layouts" --if-absent=: []

/** Combines an address space with Toit interpretation for the VM decoder. */
class View implements target.Target:
  memory/target.Target
  interpretation/Interpretation

  constructor .memory .interpretation:

  id -> string:
    return memory.id

  regions -> List:
    return memory.regions

  read address/int length/int -> ByteArray:
    return memory.read address length

  allows address/int length/int -> bool:
    return memory.allows address length

  observation -> Map:
    if memory is target.ObservedTarget:
      return (memory as target.ObservedTarget).observation
    return {
      "semantic-coherence": metadata["completeness"].get
          "semantic-coherence"
          --if-absent=: false,
    }

  metadata -> Map:
    return interpretation.metadata

/** Finds the Toit method containing the absolute $bci. */
method-at-bci layout/Map bci/int -> Map?:
  candidate/Map? := null
  methods/List := layout.get "methods" --if-absent=: []
  methods.do: | method/Map |
    if method["entry-bci"] > bci: return candidate
    if bci <= method["end-bci"]: candidate = method
  return candidate

/** Finds the block or method whose header starts at $header-bci. */
method-at-header-bci layout/Map header-bci/int -> Map?:
  methods/List := layout.get "methods" --if-absent=: []
  methods.do: | method/Map |
    if method["header-bci"] == header-bci: return method
  return null

/**
Symbolizes an absolute Toit bytecode index without reading VM memory.

This is the semantic entry point expected by debugger-style clients once a
  stopped target has supplied a program identity and BCI.
*/
symbolize-bci layout/Map bci/int -> Map:
  method := method-at-bci layout bci
  if not method:
    return {
      "bci": bci,
      "status": "unknown",
      "diagnostic": "METHOD_NOT_FOUND",
    }
  relative-bci := bci - method["entry-bci"]
  result := {
    "bci": bci,
    "relative-bci": relative-bci,
    "status": "symbolized",
    "method": {
      "name": method["name"],
      "kind": method["kind"],
      "header-bci": method["header-bci"],
      "entry-bci": method["entry-bci"],
      "end-bci": method["end-bci"],
      "arity": method["arity"],
      "max-height": method["max-height"],
    },
  }
  positions/List := method.get "positions" --if-absent=: []
  position := value-at-or-before_ positions relative-bci
  if position:
    result["source"] = {
      "path": method.get "path",
      "line": position.get "line",
      "column": position.get "column",
    }
  return result

value-at-or-before_ entries/List relative-bci/int -> Map?:
  candidate/Map? := null
  entries.do: | entry/Map |
    if entry["relative-bci"] > relative-bci: return candidate
    candidate = entry
  return candidate
