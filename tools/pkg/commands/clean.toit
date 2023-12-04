import system

import cli

import ..pkg
import ..project

class CleanCommand:
  project/Project
  constructor parsed/cli.Parsed:
    config := ProjectConfiguration.from-cli parsed
    config.verify
    project = Project config

  execute:
    project.clean

  static CLI-COMMAND ::=
      cli.Command "clean"
          --help="""
                 Removes unnecessary packages.

                 If a package isn't used anymore removes the downloaded files from the
                   local package cache.
                 """
          --run=:: (CleanCommand it).execute
