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
import fs
import host.file

import ..pkg
import ..registry
import ..registry.description
import ..registry.local

import .base_

class ListCommand extends PkgCommand:
  name-or-path/string?

  constructor invocation/cli.Invocation:
    name-or-path = invocation[NAME-OR-PATH-OPTION]

    super invocation

  execute:
    registry-packages := registries.list-packages
    if name-or-path:
      if registry-packages.contains name-or-path:
        registry-packages.filter --in-place: | k v | k == name-or-path
      else:
        // If the name-or-path is not a registry, we assume it is a path to a registry.
        // We try to load the registry from that path.
        if not file.is-directory name-or-path:
          ui.abort "No registry found at '$name-or-path'."
        registry := LocalRegistry (fs.basename name-or-path) name-or-path --ui=ui
        registry-packages = {
          name-or-path: {
            "registry": registry,
            "descriptions": registry.list-all-descriptions,
          }
        }

    if ui.wants-structured:
      result := registry-packages.map: | _ registry/Map |
        {
          "registry": (registry["registry"] as Registry).to-map,
          // For structured output, we always use the verbose format.
          "packages": (registry["descriptions"].map: verbose-description it)
        }
      ui.emit-map --result result
      return

    registry-packages.do: | name/string registry/Map |
      ui.emit --result "$name ($registry["registry"].to-string)"
      list-descriptions registry["descriptions"] --indent="  " --ui=ui

  /**
  Converts the $description into a map suitable for printing.
  Removes keys that should not be printed. The 'name' key is removed and the resulting map has a
    single entry mapping the name to the filtered content.

  If $allow-extra-fields, then allows dependencies and environment keys too.
  */
  static verbose-description description/Description --allow-extra-fields/bool=false -> Map:
    filtered := description.to-json.filter: | k _ |
      if k == Description.NAME-KEY_: continue.filter false
      if allow-extra-fields: continue.filter true
      if k == Description.DEPENDENCIES-KEY_: continue.filter false
      if k == Description.ENVIRONMENT-KEY_: continue.filter false
      true
    return { description.name : filtered }

  static list-descriptions descriptions/List --indent/string="" --ui/cli.Ui:
    descriptions = descriptions.sort: | a/Description b/Description |
      a.name.compare-to b.name --if-equal=:
        a.version.compare-to b.version --if-equal=:
          a.ref-hash.compare-to b.ref-hash

      if a.name < b.name: continue.sort -1
      if a.name > b.name: continue.sort 1
      if a.version < b.version: continue.sort -1
      if a.version > b.version: continue.sort 1
      0
    if ui.wants-structured:
      ui.emit-list --result descriptions
      return

    if ui.wants-human:
      if descriptions.is-empty:
        ui.emit --result "$(indent)No packages found."
        return

    // From now on the "plain" and "human" output are the same.
    // If we are not verbose, we just print the name and version of each package.
    if ui.level < cli.Ui.VERBOSE-LEVEL:
      descriptions.do: | description/Description |
        ui.emit --result "$indent$description.name - $description.version"
      return

    // Verbose output in plain or human format.
    descriptions.do: | description/Description |
      description-text := yaml.stringify (verbose-description description)
      description-text = description-text.replace --all "\n" "\n$indent"
      ui.emit --result "$indent$description-text"

  static CLI-COMMAND ::=
      cli.Command "list"
          --help="""
              Lists all packages.

              If no argument is given, lists all available packages.
              If an argument is given, it must be either a registry name or a path to a registry.
                In that case only the packages from that registry are shown.
              """
          --rest=[
              cli.Option NAME-OR-PATH-OPTION
                  --required=false
            ]
          --run=:: (ListCommand it).execute

  static NAME-OR-PATH-OPTION ::= "name-or-path"
