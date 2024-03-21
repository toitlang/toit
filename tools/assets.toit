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

import .firmware show read-file write-file

OPTION-ASSETS       ::= "assets"
OPTION-OUTPUT       ::= "output"
OPTION-OUTPUT-SHORT ::= "o"

option-output ::= cli.Option OPTION-OUTPUT
    --short-name=OPTION-OUTPUT-SHORT
    --help="Set the output assets file."
    --type="file"

main arguments/List:
  root-cmd := cli.Command "root"
      --options=[
        cli.Option OPTION-ASSETS
            --short-name="e"
            --help="Set the assets to work on."
            --type="file"
            --required
      ]
  root-cmd.add create-cmd
  root-cmd.add add-cmd
  root-cmd.add get-cmd
  root-cmd.add remove-cmd
  root-cmd.add list-cmd
  root-cmd.run arguments

create-cmd -> cli.Command:
  return cli.Command "create"
      --run=:: create-assets it

create-assets parsed/cli.Parsed -> none:
  output-path := parsed[OPTION-ASSETS]
  store-assets output-path {:}

add-cmd -> cli.Command:
  return cli.Command "add"
      --options=[
        option-output,
        cli.OptionEnum "format" ["binary", "ubjson", "tison"]
            --default="binary"
            --help="Pick the encoding format."

      ]
      --rest=[
        cli.Option "name"
            --required,
        cli.Option "path"
            --type="file"
            --required
      ]
      --help="Add or update asset with the given name."
      --run=:: add-asset it

add-asset parsed/cli.Parsed -> none:
  name := parsed["name"]
  path := parsed["path"]
  asset := read-file path
  update-assets parsed: | entries/Map |
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

get-cmd -> cli.Command:
  return cli.Command "get"
      --options=[
        cli.OptionEnum "format" ["auto", "binary", "ubjson", "tison"]
            --default="auto"
            --help="Pick the encoding format.",
        cli.Option "output"
            --short-name="o"
            --help="Set the name of the output file."
            --type="file"
            --required,
      ]
      --rest=[
        cli.Option "name"
            --required,
      ]
      --help="Get the asset with the given name."
      --run=:: get-asset it

get-asset parsed/cli.Parsed -> none:
  input-path := parsed[OPTION-ASSETS]
  output-path := parsed["output"]
  name := parsed["name"]
  format := parsed["format"]
  entries := load-assets input-path
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
    print "Failed to decode asset '$name' as $format.to-ascii-upper"
    exit 1
  write-file output-path: it.write content

remove-cmd -> cli.Command:
  return cli.Command "remove"
      --options=[ option-output ]
      --rest=[
        cli.Option "name"
            --required,
      ]
      --help="Remove asset with the given name."
      --run=:: remove-asset it

remove-asset parsed/cli.Parsed -> none:
  name := parsed["name"]
  update-assets parsed: | entries/Map |
    entries.remove name

list-cmd -> cli.Command:
  return cli.Command "list"
      --help="Print all assets in JSON."
      --run=:: list-assets it

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

list-assets parsed/cli.Parsed -> none:
  input-path := parsed[OPTION-ASSETS]
  entries := load-assets input-path
  mapped := entries.map: | _ content/ByteArray |
    entry := { "size": content.size }
    entry["kind"] = decode entry content
    entry
  print (json.stringify mapped)

update-assets parsed/cli.Parsed [block] -> none:
  input-path := parsed[OPTION-ASSETS]
  output-path := parsed[OPTION-OUTPUT]
  if not output-path: output-path = input-path

  existing := load-assets input-path
  block.call existing
  store-assets output-path existing

load-assets path/string -> Map:
  bytes := read-file path
  return assets.decode bytes

store-assets path/string entries/Map -> none:
  bytes := assets.encode entries
  write-file path: it.write bytes
