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

import .base_
import .completions_
import .utils_

class UpdateCommand extends PkgProjectCommand:
  prefixes/List

  constructor invocation/cli.Invocation:
    prefixes = invocation[PREFIX]
    super invocation

  execute:
    project.update prefixes --registries=registries

  static CLI-COMMAND ::=
      cli.Command "update"
          --help="""
              Updates packages to their newest compatible version.

              Uses semantic versioning to find the highest compatible version
                of each selected package. Dependencies are also updated when
                required by the selected versions.

              If no prefixes are given, updates all packages.
              """
          --rest=[
              cli.Option PREFIX
                  --help="The prefix of a package to update."
                  --type="prefix"
                  --multi
                  --completion=:: complete-dependency-prefixes it --project-root-option=OPTION-PROJECT-ROOT
          ]
          --run=:: (UpdateCommand it).execute

  static PREFIX ::= "prefix"
