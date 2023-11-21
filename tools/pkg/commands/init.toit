import cli
import host.file

import ..error
import ..project
import ..project.package

class InitCommand:
  project/Project
  constructor parsed/cli.Parsed:
    project = project-from-cli cli --ignore-missing

  execute:
    if project.
    print "Toit package manager version: $system.vm-sdk-version"

  static CLI-COMMAND ::=
      cli.Command "init"
          --short-help="Creates a new package and lock file in the current directory"
          --long_help="""
                      Initializes the current directory as the root of the project.

                      This is done by creating a 'package.lock' and 'package.yaml' file.

                      If the --project-root flag is used, initializes that directory instead.
                      """
          --run=:: (InitCommand it).execute

