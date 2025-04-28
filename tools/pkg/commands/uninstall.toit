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

class UninstallCommand:
  name/string
  project/Project
  constructor invocation/cli.Invocation:
    name = invocation[NAME]

    config := project-configuration-from-cli invocation
    config.verify
    project = Project config

  execute:
    project.uninstall name

  static CLI-COMMAND ::=
      cli.Command "uninstall"
          --help="""
              Uninstalls the package with the given name.

              Removes the package of the given name from the package files.
                The downloaded code is not automatically deleted.
              """
          --rest=[
              cli.Option NAME
                  --help="The name of the package to uninstall."
                  --required
          ]
          --run=:: (UninstallCommand it).execute

  static NAME ::= "name"
