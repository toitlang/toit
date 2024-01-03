// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

import cli

import ..pkg

class VersionCommand:
  constructor parsed/cli.Parsed:

  execute:
    print "Toit package manager version: $system.vm-sdk-version"

  static CLI-COMMAND ::=
      cli.Command "version"
          --help="Prints the version of the package manager"
          --run=:: (VersionCommand it).execute
