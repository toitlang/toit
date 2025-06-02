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
import ..registry

import .base_

class SyncCommand extends PkgCommand:
  constructor invocation/cli.Invocation:
    super invocation

  execute:
    registries.sync

  static CLI-COMMAND ::=
      cli.Command "sync"
          --help="""
              Synchronizes all registries.

              This is an alias for 'toit.pkg registry sync'
              """
          --run=:: (SyncCommand it).execute
