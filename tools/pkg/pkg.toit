import cli

import .install

clean parsed/cli.Parsed: print "NYI: clean"
completion parsed/cli.Parsed: print "NYI: completion"
describe parsed/cli.Parsed: print "NYI: describe"
init parsed/cli.Parsed: print "NYI: init"
list parsed/cli.Parsed: print "NYI: list"
registry parsed/cli.Parsed: print "NYI: registry"
search parsed/cli.Parsed: print "NYI: search"
sync parsed/cli.Parsed: print "NYI: sync"
update parsed/cli.Parsed: print "NYI: sync"
uninstall parsed/cli.Parsed: print "NYI: update"
version parsed/cli.Parsed: print "NYI: update"

//  clean        Removes unnecessary packages
//  completion  Generate the autocompletion script for the specified shell
//  describe    Generates a description of the given package
//  init        Creates a new package and lock file in the current directory
//  install     Installs a package in the current project, or downloads all dependencies
//  list        Lists all available packages
//  registry    Manages registries
//  search      Searches for the given name in all packages
//  sync        Synchronizes all registries
//  uninstall   Uninstalls the package with the given name
//  update      Updates all packages to their newest versions
//  version     Prints the version of the package manager

main arguments/List:
  pkg := cli.Command "pkg"
      --usage="toit.pkg [command]"
      --short-help="The Toit package manager"
      --subcommands=[
          cli.Command "clean"
              --short-help="Removes unnecessary packages"
              --long-help="""
                          Removes unnecessary packages.

                          If a package isn't used anymore removes the downloaded files from the
                            local package cache."""
              --run=:: clean it,

          cli.Command "completion"
              --short-help="Generate the autocompletion script for the specified shell"
              --run=:: completion it,

          cli.Command "describe"
              --short-help="Generates a description of the given package"
              --run=:: describe it,

          cli.Command "init"
              --short-help="Creates a new package and lock file in the current directory"
              --run=:: init it,

          InstallCommand.CLI-COMMAND,

          cli.Command "list"
              --short-help="Lists all available packages"
              --run=:: list it,

          cli.Command "registry"
              --short-help="Manages registries"
              --run=:: registry it,

          cli.Command "search"
              --short-help="Searches for the given name in all packages"
              --long-help="""
                          Searches in the name, and description entries, as well as in the URLs of
                          the packages."""
              --options=[
                  cli.Flag "verbose" --short-name="v" --short-help="Show more information"
              ]
              --run=:: search it,

          cli.Command "sync"
              --short-help="Synchronizes all registries"
              --run=:: sync it,

          cli.Command "uninstall"
              --short-help="Uninstalls the package with the given name"
              --run=:: uninstall it,

          cli.Command "update"
              --short-help="Updates all packages to their newest versions"
              --run=:: update it,

          cli.Command "version"
              --short-help="Prints the version of the package manager"
              --run=:: version it
      ]

      --options=[
          cli.Flag "auto-sync"
              --short-help="automatically synchronize registries (default true)",

          cli.OptionString "project-root"
              --short-help="specify the project root",

          cli.OptionString "sdk-version"
              --short-help="specify the SDK version"
      ]

  pkg.run arguments

error msg/string:
  print msg
  exit 1