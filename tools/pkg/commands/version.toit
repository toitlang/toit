import ..pkg
import cli

class VersionCommand:
  constructor parsed/cli.Parsed:

  execute:
    print "Toit package manager version: $VERSION"

  static CLI-COMMAND ::=
      cli.Command "version"
          --short-help="Prints the version of the package manager"
          --run=:: (VersionCommand it).execute
