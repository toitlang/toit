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

import encoding.json
import writer
import system.assets

import cli
import host.file

OPTION_ASSETS       ::= "assets"
OPTION_OUTPUT       ::= "output"
OPTION_OUTPUT_SHORT ::= "o"

option_output ::= cli.OptionString OPTION_OUTPUT
    --short_name=OPTION_OUTPUT_SHORT
    --short_help="Set the output assets file."
    --type="file"

main arguments/List:
  root_cmd := cli.Command "root"
      --options=[
        cli.OptionString OPTION_ASSETS
            --short_name="a"
            --short_help="Set the envelope to work on."
            --type="file"
            --required
      ]
  root_cmd.add create_cmd
  root_cmd.add add_cmd
  root_cmd.add remove_cmd
  root_cmd.add list_cmd
  root_cmd.run arguments

create_cmd -> cli.Command:
  return cli.Command "create"
      --run=:: create_assets it

create_assets parsed/cli.Parsed -> none:
  output_path := parsed[OPTION_ASSETS]
  store_assets output_path {:}

add_cmd -> cli.Command:
  return cli.Command "add"
      --options=[ option_output ]
      --rest=[
        cli.OptionString "name"
            --required,
        cli.OptionString "path"
            --type="file"
            --required
      ]
      --run=:: add_asset it

add_asset parsed/cli.Parsed -> none:
  name := parsed["name"]
  path := parsed["path"]
  asset := file.read_content path
  update_assets parsed: | entries/Map |
    entries[name] = asset

remove_cmd -> cli.Command:
  return cli.Command "remove"
      --options=[ option_output ]
      --rest=[
        cli.OptionString "name"
            --required,
      ]
      --run=:: remove_asset it

remove_asset parsed/cli.Parsed -> none:
  name := parsed["name"]
  update_assets parsed: | entries/Map |
    entries.remove name

list_cmd -> cli.Command:
  return cli.Command "list"
      --run=:: list_assets it

list_assets parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ASSETS]
  entries := load_assets input_path
  mapped := entries.map: | _ content/ByteArray | { "size": content.size }
  print (json.stringify mapped)

update_assets parsed/cli.Parsed [block] -> none:
  input_path := parsed[OPTION_ASSETS]
  output_path := parsed[OPTION_OUTPUT]
  if not output_path: output_path = input_path

  existing := load_assets input_path
  block.call existing
  store_assets output_path existing

load_assets path/string -> Map:
  bytes := file.read_content path
  return assets.decode bytes

store_assets path/string entries/Map -> none:
  output_stream := file.Stream.for_write path
  bytes := assets.encode entries
  output_stream.write bytes
  output_stream.close
