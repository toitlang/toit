// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import cli
import host.file

import ..error
import ..project
import ..project.package

class InitCommand:
  project/Project

  constructor parsed/cli.Parsed:
    config := ProjectConfiguration.from-cli parsed

    if config.package-file-exists or config.lock-file-exists:
      error "Directory already contains a project"

    project = Project config --empty-lock-file

  execute:
    project.save

  static CLI-COMMAND ::=
      cli.Command "init"
          --help="""
              Initializes the current directory as the root of the project.

              This is done by creating a 'package.lock' and 'package.yaml' file.

              If the --project-root flag is used, initializes that directory instead.
              """
          --run=:: (InitCommand it).execute

