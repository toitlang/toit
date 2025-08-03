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

import ..pkg
import ..registry
import ..registry.description
import ..semantic-version

import .base_
import .list

class SearchCommand extends PkgCommand:
  verbose/bool
  search-string/string

  constructor invocation/cli.Invocation:
    verbose = invocation[VERBOSE-OPTION]
    search-string = invocation[NAME-OPTION]
    super invocation

  execute:
    registries.sync
    search-result := registries.search --free-text search-string
    search-result = search-result.sort: | a/Description b/Description |
      a.name.compare-to b.name --if-equal=:
        a.url.compare-to b.url --if-equal=:
          a.version.compare-to b.version

    url-to-description/Map := {:}
    search-result.do: | description/Description |
      version := description.version
      old/Description? := url-to-description.get description.url
      if not old:
        url-to-description[description.url] = description
      else:
        if version > old.version:
          url-to-description[description.url] = description
    ListCommand.list-descriptions url-to-description.values --verbose=verbose --ui=ui

  static CLI-COMMAND ::=
      cli.Command "search"
          --help="""
              Searches for the given name in all packages.

              Searches in the name, and description entries, as well as in the URLs of
              the packages.
              """
          --rest=[
              cli.Option NAME-OPTION
                  --help="The name to search for."
                  --required
          ]
          --options=[
              cli.Flag VERBOSE-OPTION
                  --short-name="v"
                  --help="Show more information."
                  --default=false
          ]
          --run=:: (SearchCommand it).execute

  static VERBOSE-OPTION ::= "verbose"
  static NAME-OPTION    ::= "name"
