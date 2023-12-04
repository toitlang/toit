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

// TODO(mikkel): implement completion in the cli package

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
              --help="Automatically synchronize registries (default true)"
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

