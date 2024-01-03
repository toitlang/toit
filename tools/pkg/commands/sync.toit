// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

import cli

import ..pkg
import ..registry

class SyncCommand:
  constructor parsed/cli.Parsed:

  execute:
    registries.sync

  static CLI-COMMAND ::=
      cli.Command "sync"
          --help="""
              Synchronizes all registries.

              This is an alias for 'toit.pkg registry sync'
              """
          --run=:: (SyncCommand it).execute
