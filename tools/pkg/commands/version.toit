import ..pkg
import cli
import system

class VersionCommand:
  constructor parsed/cli.Parsed:

  execute:
    print "Toit package manager version: $system.vm-sdk-version"

  static CLI-COMMAND ::=
      cli.Command "version"
          --short-help="Prints the version of the package manager"
          --run=:: (VersionCommand it).execute
