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

import encoding.base64 as base64
import cli
import host.file
import encoding.json
import host.pipe
import bytes
import .snapshot

main args:
  command := null
  command = cli.Command "root"
      --long_help="""
      Dumps propagated types.

      Run the compiler with '-Xpropagate -w program.snapshot program.toit > program.types'.
      Then use the generated snapshot and types for this tool.
      """
      --short_help="Dumps propagated types."
      --options=[
        cli.OptionString "snapshot" --required --short_name="s"
            --short_help="The snapshot file for the program."
            --type="file",
        cli.OptionString "types" --required --short_name="t"
            --short_help="The collected types in a JSON file."
            --type="file",
        cli.Flag "sdk"
            --short_help="Show types for the sdk."
            --default=false,
        cli.Flag "show-positions" --short_name="p"
            --default=false,
      ]
      --run=:: decode_types it command
  command.run args

decode_types parsed command -> none:
  snapshot_content := file.read_content parsed["snapshot"]
  types_content := file.read_content parsed["types"]
  types := json.decode types_content
  show_types types snapshot_content
      --sdk=parsed["sdk"]
      --show_positions=parsed["show-positions"]

show_types types/List snapshot_content/ByteArray -> none
    --sdk/bool
    --show_positions/bool:
  bundle := SnapshotBundle snapshot_content
  program := bundle.decode
  methods := {}
  input_strings := {:}
  output_strings := {:}
  method_args := {:}
  types.do: | entry/Map |
    position := entry["position"]
    method/ToitMethod := ?
    if entry.contains "output":
      method = program.method_from_absolute_bci position
      output_strings[position] = type_string program entry["output"]
      if entry.contains "input":
        input_strings[position] = entry["input"].map: | x |
          type_string program x
    else:
      method = program.method_from_absolute_bci (position + ToitMethod.HEADER_SIZE)
      method_args[position] = entry["arguments"].map: | x |
        type_string program x
    methods.add method

  sorted_methods := List.from methods
  if not sdk:
    sorted_methods = sorted_methods.filter: | method/ToitMethod |
      info := program.method_info_for method.id
      not info.error_path.starts_with "<sdk>"
  sorted_methods.sort --in_place: | a/ToitMethod b/ToitMethod |
    ia := program.method_info_for a.id
    ib := program.method_info_for b.id
    ia.error_path.compare_to ib.error_path --if_equal=:
      ia.position.line.compare_to ib.position.line --if_equal=:
        ia.name.compare_to ib.name --if_equal=:
          // Being dependant on the method position in the
          // bytecode stream isn't great, but as a last
          // resort for sorting it works since it is only
          // used to sort different adapter stubs using
          // their (predictable) order of generation.
          ia.id.compare_to ib.id

  first := true
  sorted_methods.do: | method/ToitMethod |
    if first: first = false
    else: print ""
    args := method_args.get method.id
    method.output program args --show_positions=show_positions: | position/int |
      input_part := null
      if input_strings.contains position:
        input_part = input_strings[position]
      output_part := null
      if output_strings.contains position:
        output_part = output_strings[position]
      comment := null
      if input_part:
        if output_part:
          comment = "$input_part -> $output_part"
        else:
          comment = "$input_part -> none"
      else:
        comment = output_part
      comment

type_string program/Program type/any -> string:
  if type == "[]": return "[block]"
  if type == "*": return "{*}"
  names := type.map: | id |
    program.class_name_for id
  return "{$(names.join "|")}"
