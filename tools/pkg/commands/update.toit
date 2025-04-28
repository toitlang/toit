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

import system

import cli

import ..pkg
import ..project

import .utils_

class UpdateCommand:
  project/Project

  constructor invocation/cli.Invocation:
    config := project-configuration-from-cli invocation
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
