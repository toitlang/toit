import system

import cli

import ..pkg
import ..registry
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

    url-to-package/Map := {:}
    search-result.do: | package |
      version-string/string := package[1]
      package-description/Map := package[2]
      url := package-description[Description.URL-KEY_]
      version := SemanticVersion version-string
      old := url-to-package.get url
      if not old:
        url-to-package[url] = package
      else:
        old-version := SemanticVersion old[1]
        if version > old-version:
          url-to-package[url] = package
    ListCommand.list-textual url-to-package.values --verbose=verbose

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
