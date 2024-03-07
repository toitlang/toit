// Copyright (C) 2024 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import cli
import host.file

import ..error
import ..project
import ..project.package

import .utils_

class InitCommand:
  project/Project

  constructor parsed/cli.Parsed:
    config := project-configuration-from-cli parsed

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

