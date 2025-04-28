#!/usr/bin/env toit

// Copyright (C) 2022 Toitware ApS.
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

import cli
import encoding.base64 as base64
import encoding.json
import host.file
import host.pipe
import .snapshot

main args:
  command := null
  command = cli.Command "root"
      --help="""
      Dumps propagated types.

      Run the compiler with '-Xpropagate -w program.snapshot program.toit > program.types'.
      Then use the generated snapshot and types for this tool.
      """
      --options=[
        cli.Option "snapshot" --required --short-name="s"
            --help="The snapshot file for the program."
            --type="file",
        cli.Option "types" --required --short-name="t"
            --help="The collected types in a JSON file."
            --type="file",
        cli.Flag "sdk"
            --help="Show types for the sdk."
            --default=false,
        cli.Flag "show-positions" --short-name="p"
            --default=false,
      ]
      --run=:: decode-types it
  command.run args

decode-types invocation/cli.Invocation -> none:
  snapshot-content := file.read-contents invocation["snapshot"]
  types-content := file.read-contents invocation["types"]
  types := json.decode types-content
  show-types types snapshot-content
      --sdk=invocation["sdk"]
      --show-positions=invocation["show-positions"]

show-types types/List snapshot-content/ByteArray -> none
    --sdk/bool
    --show-positions/bool:
  bundle := SnapshotBundle snapshot-content
  program := bundle.decode
  methods := {}
  input-strings := {:}
  output-strings := {:}
  method-args := {:}
  types.do: | entry/Map |
    position := entry["position"]
    method/ToitMethod := ?
    if entry.contains "output":
      method = program.method-from-absolute-bci position
      output-strings[position] = type-string program entry["output"]
      if entry.contains "input":
        input-strings[position] = entry["input"].map: | x |
          type-string program x
    else:
      method = program.method-from-absolute-bci (position + ToitMethod.HEADER-SIZE)
      method-args[position] = entry["arguments"].map: | x |
        type-string program x
    methods.add method

  sorted-methods := List.from methods
  if not sdk:
    sorted-methods = sorted-methods.filter: | method/ToitMethod |
      info := program.method-info-for method.id
      not info.error-path.starts-with "<sdk>"
  sorted-methods.sort --in-place: | a/ToitMethod b/ToitMethod |
    ia := program.method-info-for a.id
    ib := program.method-info-for b.id
    ia.error-path.compare-to ib.error-path --if-equal=:
      ia.position.line.compare-to ib.position.line --if-equal=:
        ia.name.compare-to ib.name --if-equal=:
          // Being dependant on the method position in the
          // bytecode stream isn't great, but as a last
          // resort for sorting it works since it is only
          // used to sort different adapter stubs using
          // their (predictable) order of generation.
          ia.id.compare-to ib.id

  first := true
  sorted-methods.do: | method/ToitMethod |
    if first: first = false
    else: print ""
    args := method-args.get method.id
    method.output program args --show-positions=show-positions: | position/int |
      input-part := input-strings.get position
      output-part := output-strings.get position
      input-part ? "$input-part -> $output-part" : output-part

type-string program/Program type/any -> string:
  if type == "[]": return "[block]"
  if type == "*": return "{*}"
  names := type.map: | id |
    program.class-name-for id
  return "{$(names.join "|")}"
