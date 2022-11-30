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
      ]
      --run=:: decode_types it command
  command.run args

decode_types parsed command -> none:
  if not parsed: exit 1
  snapshot_content := file.read_content parsed["snapshot"]
  types_content := file.read_content parsed["types"]
  types := json.decode types_content
  show_types --sdk=parsed["sdk"] types snapshot_content

show_types --sdk/bool types/List snapshot_content/ByteArray -> none:
  bundle := SnapshotBundle snapshot_content
  program := bundle.decode
  methods := {}
  type_strings := {:}
  method_args := {:}
  types.do: | entry/Map |
    position := entry["position"]
    method := program.method_from_absolute_bci position
    methods.add method
    if entry.contains "type":
      type_strings[position] = type_string program entry["type"]
    else:
      method_args[position] = entry["arguments"].map: | x |
        type_string program x

  sorted_methods := List.from methods
  if not sdk:
    sorted_methods = sorted_methods.filter: | method/ToitMethod |
      info := program.method_info_for method.id
      not info.error_path.starts_with "<sdk>"
  sorted_methods.sort --in_place: | a/ToitMethod b/ToitMethod |
    ia := program.method_info_for a.id
    ib := program.method_info_for b.id
    ia.error_path.compare_to ib.error_path --if_equal=:
      ia.position.line.compare_to ib.position.line

  first := true
  sorted_methods.do: | method/ToitMethod |
    if first: first = false
    else: print ""
    args := method_args.get method.id
    method.output program args --no-show_positions: | position/int |
      type_strings.get position

type_string program/Program type/any -> string:
  if type == "[]": return "[block]"
  if type == "*": return "{*}"
  names := type.map: | id |
    program.class_name_for id
  return "{$(names.join "|")}"
