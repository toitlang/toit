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
