import system

import cli

import ..pkg
import ..project

class UpdateCommand:
  project/Project

  constructor parsed/cli.Parsed:
    config := ProjectConfiguration.from-cli parsed
    config.verify
    project = Project config

  execute:
    project.update

  static CLI-COMMAND ::=
      cli.Command "update"
          --help="""
                 Updates all packages to their newest compatible version.

                 Uses semantic versioning to find the highest compatible version
                   of each imported package (and their transitive dependencies).
                   It then updates all packages to these versions.
                 """
          --run=:: (UpdateCommand it).execute
