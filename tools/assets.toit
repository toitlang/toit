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

import writer
import system.assets

import cli
import host.file

import encoding.json
import encoding.ubjson
import encoding.tison

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
  root_cmd.add get_cmd
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
        cli.OptionEnum "format" ["binary", "ubjson", "tison"]
            --default="binary"
            --short_help="Pick the encoding format."

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
  asset := read_file path
  update_assets parsed: | entries/Map |
    if parsed["format"] != "binary":
      decoded := null
      exception := catch: decoded = json.decode asset
      if not decoded:
        print "Unable to decode '$path' as JSON. ($exception)"
        exit 1
      if parsed["format"] == "ubjson":
        asset = ubjson.encode decoded
      else if parsed["format"] == "tison":
        asset = tison.encode decoded
      else:
        unreachable
    entries[name] = asset

get_cmd -> cli.Command:
  return cli.Command "get"
      --options=[
        cli.OptionEnum "format" ["auto", "binary", "ubjson", "tison"]
            --default="auto"
            --short_help="Pick the encoding format.",
        cli.OptionString "output"
            --short_name="o"
            --short_help="Set the name of the output file."
            --type="file"
            --required,
      ]
      --rest=[
        cli.OptionString "name"
            --required,
      ]
      --short_help="Get the asset with the given name."
      --run=:: get_asset it

get_asset parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ASSETS]
  output_path := parsed["output"]
  name := parsed["name"]
  format := parsed["format"]
  entries := load_assets input_path
  entry := entries.get name
  if not entry:
    print "No such asset: $name"
    exit 1
  content := entry
  exception := null
  if format == "auto":
    decoded := null
    catch: decoded = decoded or "$(json.stringify (tison.decode content))\n"
    catch: decoded = decoded or "$(json.stringify (ubjson.decode content))\n"
    catch: decoded = decoded or "$(json.stringify (json.decode content))\n"
    content = decoded or content
  else if format == "tison":
    exception = catch: content = "$(json.stringify (tison.decode content))\n"
  else if format == "ubjson":
    exception = catch: content = "$(json.stringify (ubjson.decode content))\n"
  if exception:
    print "Failed to decode asset '$name' as $format.to_ascii_upper"
    exit 1
  write_file output_path: it.write content

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
    entry["data"] = tison.decode content
    return "tison"
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
