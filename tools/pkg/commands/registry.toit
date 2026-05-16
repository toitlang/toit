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
import fs

import ..pkg
import ..registry
import ..registry.local

import .base_

class RegistryCommand extends PkgCommand:
  static LOCAL     ::= "local"
  static NAME      ::= "name"
  static LOCATION   ::= "location"
  static CLEAR-CACHE ::= "clear-cache"

  local/bool := false
  url/string? := null
  name/string? := null
  clear-cache/bool := false

  constructor.add invocation/cli.Invocation:
    local = invocation[LOCAL]
    url = invocation[LOCATION]
    name = invocation[NAME]

    super invocation

  constructor.remove invocation/cli.Invocation:
    name = invocation[NAME]
    super invocation

  constructor.sync invocation/cli.Invocation:
    name = invocation[NAME]
    clear-cache = invocation[CLEAR-CACHE]
    super invocation

  constructor.list invocation/cli.Invocation:
    super invocation

  add:
    url-or-path := url
    if local:
      url-or-path = fs.to-absolute url-or-path

    if registries.registries.contains name:
      registry/Registry := registries.registries[name]
      if registry is LocalRegistry:
        local-registry := registry as LocalRegistry
        if local-registry.path == url-or-path:
          // Already exists with the same path.
          return
      else:
        git-registry := registry as GitRegistry
        if git-registry.url == url-or-path:
          // Already exists with the same URL.
          return
      ui.abort "Registry $name already exists with a different URL or path."
    if local:
      registries.add --local name url-or-path
    else:
      registries.add --git name url-or-path

  remove:
    registries.remove name

  list:
    registries.list

  sync:
    if not name:
      registries.sync --clear-cache=clear-cache
    else:
      registries.sync --name=name --clear-cache=clear-cache

  static CLI-COMMAND ::=
      cli.Command "registry"
          --help="Manages registries."
          --subcommands=[
                cli.Command "add"
                    --help="""
                        Adds a registry.

                        The 'name' of the registry must not be used yet.

                        By default the 'URL' is interpreted as Git-URL.
                          If the '--local' flag is used, then the 'URL' is interpreted as local
                          path to a folder containing package descriptions.
                        """
                    --rest=[
                        cli.Option NAME
                            --help="Name of the registry"
                            --required,

                        cli.Option LOCATION // Either a URL or a path.
                            --type="URL/Path"
                            --help="Location of the registry, depending on the local flag"
                            --required
                      ]
                    --options=[
                          cli.Flag LOCAL
                              --help="Registry is local."
                              --default=false
                      ]
                    --examples=[
                          cli.Example --arguments="user ~/user-repository --local"
                              """
                              Add a local registry with name user located at the path ~/user-repository.
                              """,

                          cli.Example --arguments="toit github.com/toitware/registry"
                              """
                              Add the toit registry.
                              """
                    ]
                    --run=:: (RegistryCommand.add it).add,

                cli.Command "remove"
                    --help="""
                        Removes a registry.

                        The 'name' of the registry must exist.
                        """
                    --rest=[
                        cli.Option "name"
                            --help="Name of the registry"
                            --required
                      ]
                    --run=:: (RegistryCommand.remove it).remove,

                cli.Command "list"
                    --help="List registries"
                    --run=:: (RegistryCommand.list it).list,

                cli.Command "sync"
                    --help="""
                        Synchronizes all registries.

                        If no argument is given, synchronizes all registries.
                        If an argument is given, only that registry is synchronized.
                        """
                    --options=[
                        cli.Flag CLEAR-CACHE
                            --help="Clear the cache before synchronizing."
                            --default=false
                      ]
                    --rest=[
                        cli.Option "name"
                            --help="Name of the registry"
                            --required=false
                      ]
                    --run=:: (RegistryCommand.sync it).sync,
          ]
