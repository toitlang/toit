// Copyright (C) 2024 Toitware ApS.
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

import system

import cli
import encoding.json
import encoding.yaml

import ..pkg
import ..registry
import ..registry.description

import .base_

class ListCommand extends PkgCommand:
  name/string?
  verbose/bool
  output/string

  constructor invocation/cli.Invocation:
    name = invocation[NAME-OPTION]
    verbose = invocation[VERBOSE-OPTION]
    output = invocation[OUTPUT-OPTION]

    super invocation

  execute:
    registry-packages := registries.list-packages
    if name:
      if not registry-packages.contains name:
        error "Registry not found: $name"
      registry-packages.filter --in-place: | k v | k == name

    if output == "list":
      registry-packages.do: | registry-name registry/Map |
        print "$registry-name: $(registry["registry"].stringify)"
        list-textual registry["descriptions"] --verbose=verbose --indent="  "
    else:
      result/Map := ?
      if verbose:
        result = registry-packages.map: | registry-name registry/Map |
          { "registry": registry["registry"].to-map,
            "packages": (registry["descriptions"].map: verbose-description it)
          }
      else:
        result = registry-packages.map: | registry-name registry/Map |
          { "registry": registry["registry"].stringify,
            "packages": (registry["descriptions"].map: | description/Description | {
              description.name : description.version
            })
          }
      if output == "json":
        print (json.stringify result)
      else if output == "yaml":
        print (yaml.stringify result)

  /**
  Converts the $description into a map suitable for printing.
  Removes keys that should not be printed. The 'name' key is removed and the resulting map has a
    single entry mapping the name to the filtered content.

  If $allow-extra-fields, then allows dependencies and environment keys too.
  */
  static verbose-description description/Description --allow-extra-fields=false -> Map:
    filtered := description.content.filter: | k _ |
                  k != Description.NAME-KEY_ and
                       (allow-extra-fields or
                        k != Description.DEPENDENCIES-KEY_ and k != Description.ENVIRONMENT-KEY_)
    return { description.name : filtered }

  static list-textual descriptions/List --verbose/bool --indent/string="":
    descriptions.do: | description/Description |
      if verbose:
        description-text := (yaml.stringify (verbose-description description))
        print "$indent$((description-text.split "\n").join "\n$indent")"
      else:
        print "$indent$description.name - $description.version"

  static CLI-COMMAND ::=
      cli.Command "list"
          --help="""
              Lists all packages.

              If no argument is given, lists all available packages.
              If an argument is given, it must point to a registry path. In that case
                only the packages from that registry are shown.
              """
          --rest=[
              cli.Option NAME-OPTION
                  --required=false
            ]
          --options=[
              cli.Flag VERBOSE-OPTION
                  --short-name="v"
                  --help="Show more information about each package."
                  --default=false,
              cli.OptionEnum OUTPUT-OPTION ["list", "json", "yaml"]
                  --short-name="o"
                  --help="Output format."
                  --default="list"
            ]
          --run=:: (ListCommand it).execute

  static NAME-OPTION ::= "name"
  static VERBOSE-OPTION ::= "verbose"
  static OUTPUT-OPTION ::= "output"
