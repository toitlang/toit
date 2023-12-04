import system

import cli

import ..pkg
import ..project

class UninstallCommand:
  name/string
  project/Project
  constructor parsed/cli.Parsed:
    name = parsed[NAME]

    config := ProjectConfiguration.from-cli parsed
    config.verify
    project = Project config

  execute:
    project.uninstall name

  static CLI-COMMAND ::=
      cli.Command "uninstall"
          --help="""
                 Uninstalls the package with the given name.

                 Removes the package of the given name from the package files.
                   The downloaded code is not automatically deleted.
                 """
          --rest=[
              cli.Option NAME
                  --help="The name of the package to uninstall."
                  --required
          ]
          --run=:: (UninstallCommand it).execute

  static NAME ::= "name"