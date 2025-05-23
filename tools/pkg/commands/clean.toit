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
import .utils_

class CleanCommand extends PkgProjectCommand:
  constructor invocation/cli.Invocation:
    super invocation

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
