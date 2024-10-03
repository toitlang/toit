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

import .utils_

class InitCommand:
  static NAME ::= "name"
  static DESCRIPTION ::= "description"

  project/Project

  constructor invocation/cli.Invocation:
    config := project-configuration-from-cli invocation
    name := invocation[NAME]
    description := invocation[DESCRIPTION]

    if config.specification-file-exists or config.lock-file-exists:
      error "Directory already contains a project"

    project = Project config --empty-lock-file
    if name: project.specification.name = name
    if description: project.specification.description = description

  execute:
    project.save

  static CLI-COMMAND ::=
      cli.Command "init"
          --help="""
              Initializes the current directory as the root of the project.

              This is done by creating a 'package.lock' and 'package.yaml' file.

              If the --project-root flag is used, initializes that directory instead.
              """
          --options=[
              cli.Option NAME
                  --help="The name of the project.",
              cli.Option DESCRIPTION
                  --help="The description of the project.",
          ]
          --run=:: (InitCommand it).execute

