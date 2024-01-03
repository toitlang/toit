// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
