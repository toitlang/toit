// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
