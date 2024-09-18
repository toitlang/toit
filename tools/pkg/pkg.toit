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

import .commands.install
import .commands.version
import .commands.update
import .commands.init
import .commands.registry
import .commands.sync
import .commands.uninstall
import .commands.clean
import .commands.list
import .commands.search
import .commands.describe

// TODO(florian): implement completion in the cli package

main arguments/List:
  pkg := cli.Command "pkg"
      --usage="toit.pkg [command]"
      --help="The Toit package manager"
      --subcommands=[
          CleanCommand.CLI-COMMAND,
          DescribeCommand.CLI-COMMAND,
          InitCommand.CLI-COMMAND,
          InstallCommand.CLI-COMMAND,
          ListCommand.CLI-COMMAND,
          RegistryCommand.CLI-COMMAND,
          SearchCommand.CLI-COMMAND,
          SyncCommand.CLI-COMMAND,
          UninstallCommand.CLI-COMMAND,
          UpdateCommand.CLI-COMMAND,
          VersionCommand.CLI-COMMAND
      ]
      --options=[
          cli.Flag OPTION-AUTO-SYNC
              --help="Automatically synchronize registries."
              --default=true,

          cli.Option OPTION-PROJECT-ROOT
              --help="Specify the project root.",

          cli.Option OPTION-SDK-VERSION
              --help="Specify the SDK version."
              --default=system.vm-sdk-version
      ]
  pkg.check
  pkg.run arguments

OPTION-SDK-VERSION ::= "sdk-version"
OPTION-PROJECT-ROOT ::= "project-root"
OPTION-AUTO-SYNC ::= "auto-sync"

