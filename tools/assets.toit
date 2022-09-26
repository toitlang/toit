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
import encoding.ubjson
import writer
import system.assets

import cli
import host.file

import .firmware show read_file write_file

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
            --short_name="e"
            --short_help="Set the assets to work on."
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
      --options=[
        option_output,
        cli.Flag "ubjson"
            --short_help="Encode the asset as UBJSON."
      ]
      --rest=[
        cli.OptionString "name"
            --required,
        cli.OptionString "path"
            --type="file"
            --required
      ]
      --short_help="Add or update asset with the given name."
      --run=:: add_asset it

add_asset parsed/cli.Parsed -> none:
  name := parsed["name"]
  path := parsed["path"]
  encode_as_ubjson := parsed["ubjson"]
  asset := read_file path
  update_assets parsed: | entries/Map |
    if encode_as_ubjson:
      decoded := null
      exception := catch: decoded = json.decode asset
      if not decoded:
        print "Unable to decode '$path' as JSON. ($exception)"
        exit 1
      asset = ubjson.encode decoded
    entries[name] = asset

remove_cmd -> cli.Command:
  return cli.Command "remove"
      --options=[ option_output ]
      --rest=[
        cli.OptionString "name"
            --required,
      ]
      --short_help="Remove asset with the given name."
      --run=:: remove_asset it

remove_asset parsed/cli.Parsed -> none:
  name := parsed["name"]
  update_assets parsed: | entries/Map |
    entries.remove name

list_cmd -> cli.Command:
  return cli.Command "list"
      --short_help="Print all assets in JSON."
      --run=:: list_assets it

decode entry/Map content/ByteArray -> string:
  catch:
    entry["data"] = ubjson.decode content
    return "ubjson"
  catch:
    entry["data"] = json.decode content
    return "json"
  return "binary"

list_assets parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ASSETS]
  entries := load_assets input_path
  mapped := entries.map: | _ content/ByteArray |
    entry := { "size": content.size }
    entry["kind"] = decode entry content
    entry
  print (json.stringify mapped)

update_assets parsed/cli.Parsed [block] -> none:
  input_path := parsed[OPTION_ASSETS]
  output_path := parsed[OPTION_OUTPUT]
  if not output_path: output_path = input_path

  existing := load_assets input_path
  block.call existing
  store_assets output_path existing

load_assets path/string -> Map:
  bytes := read_file path
  return assets.decode bytes

store_assets path/string entries/Map -> none:
  bytes := assets.encode entries
  write_file path: it.write bytes
