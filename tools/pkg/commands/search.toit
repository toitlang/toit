// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

import cli

import ..pkg
import ..registry
import ..registry.description
import ..semantic-version
import .list

class SearchCommand:
  verbose/bool
  search-string/string
  constructor parsed/cli.Parsed:
    verbose = parsed[VERBOSE-OPTION]
    search-string = parsed[NAME-OPTION]

  execute:
    search-result := registries.search --free-text search-string

    url-to-description/Map := {:}
    search-result.do: | description/Description |
      version := description.version
      old/Description := url-to-description.get description.url
      if not old:
        url-to-description[description.url] = description
      else:
        if version > old.version:
          url-to-description[description.url] = description
    ListCommand.list-textual url-to-description.values --verbose=verbose

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
                  --help="Show more information"
                  --default=false
          ]
          --run=:: (SearchCommand it).execute

  static VERBOSE-OPTION ::= "verbose"
  static NAME-OPTION    ::= "name"
