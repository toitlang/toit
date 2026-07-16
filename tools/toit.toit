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
import cli show Ui
import fs
import host.directory
import host.file
import host.pipe
import system

import .toitp as toitp
import .firmware as firmware
import .assets as assets
import .kebabify as kebabify
import .snapshot-to-image as snapshot-to-image
import .stacktrace as stacktrace
import .system-message as system-message
import .info as info
import .toitdoc as toitdoc
import .lsp.server.server as lsp
import .pkg.pkg as pkg
import .snapshot as snapshot-lib

/**
Whether the given $path is a Toit source that can be run with `toit run`.
Also accepts snapshots.

Might return true for files that aren't valid Toit source files.
*/
is-toit-source path/string -> bool:
  if path.ends-with ".toit": return true
  if not file.is-file path: return false
  contents := file.read-contents path
  if snapshot-lib.SnapshotBundle.is-bundle-content contents: return true
  if contents[0] == '#' and contents[1] == '!':
    // We accept any file that starts with a shebang line.
    return true
  return false

main args/List:
  // We don't want to add a `--version` option to the root command,
  // as that would make the option available to all subcommands.
  // Fundamentally, getting the version isn't really an option, but a
  // command. The `--version` here is just for convenience, since many
  // tools have it too.
  if args.size == 1 and args[0] == "--version":
    print system.vm-sdk-version
    return

  sdk-dir-option := cli.OptionPath "sdk-dir"
      --help="Path to the SDK root."
      --directory
      --hidden

  // Late-binding reference so the default command's callback can
  // re-dispatch through the root command group.
  root-ref/cli.CommandGroup? := null

  // The default command handles direct file arguments like `toit foo.toit`.
  // It is part of the CommandGroup below. In practice, this command's
  // run callback is usually not invoked because we intercept toit-source
  // arguments early (see below) and rewrite them to `run -- <args>`. The
  // early interception is needed so that `toit foo.toit -- arg` forwards
  // the `--` to the program rather than having the CLI parser consume it.
  // However, the callback *is* reached when the early interception doesn't
  // fire, for example `toit -- foo.toit arg1 arg2`, or when the first
  // argument isn't a known command and isn't a Toit source file.
  default-command := cli.Command "default"
      --rest=[
        cli.OptionPath "source"
            --help="The Toit source or snapshot file to run."
            --extensions=[".toit", ".snapshot"]
            --required,
        cli.Option "arg"
            --help="Argument to pass to the program."
            --multi,
      ]
      --dash-dash-is-rest
      --run=:: | invocation/cli.Invocation |
        source := invocation["source"]
        rest-args := invocation["arg"]
        // With --dash-dash-is-rest, a leading `--` is not consumed as
        // a separator but becomes the source value. Skip it and take
        // the actual source from the remaining args.
        if source == "--":
          if rest-args.is-empty:
            invocation.cli.ui.abort "Missing source file after '--'"
          source = rest-args[0]
          rest-args = rest-args[1..]
        if not is-toit-source source:
          invocation.cli.ui.abort "Unknown command or invalid source file: '$source'"
        // This path is reached when the early interception (which
        // rewrites `toit foo.toit` to `toit run -- foo.toit`) does
        // not fire. For example, `toit -- foo.toit arg1 arg2`.
        root-ref.run ["run", "--"] + [source] + rest-args

  commands-command := cli.Command "commands"
      --options=[sdk-dir-option]

  root-command := cli.CommandGroup "toit"
      --help="The Toit command line tool."
      --default=default-command
      --default-title="Run"
      --commands=commands-command
  root-ref = root-command

  toitc-from-args := :: | invocation/cli.Invocation |
      sdk-dir := invocation["sdk-dir"]
      tool-path sdk-dir "toit.compile"

  toit-from-args := :: | invocation/cli.Invocation |
      sdk-dir := invocation["sdk-dir"]
      toit-path sdk-dir

  version-command := cli.Command "version"
      --help="Print the version of the Toit SDK."
      --options=[
        // For compatibility with the v1 toit executable. This flag is used by
        // the vscode extension. The v1 executable needed the "short" output to only get
        // the version number. We are ignoring this option, since we always just print the
        // version.
        cli.Option "output" --short-name="o" --hidden
      ]
      --run=:: | invocation/cli.Invocation |
        invocation.cli.ui.emit --result system.vm-sdk-version
  commands-command.add version-command

  compile-analyze-run-options := [
    cli.Flag "show-package-warnings"
        --help="Show warnings from packages.",
    cli.Flag "Werror" --short-name="Werror"
        --help="Treat warnings as errors.",
    cli.OptionPath "project-root"
        --help="Path to the project root. Any package.lock file must be in that folder."
        --directory,
    cli.Option "X" --short-name="X"
        --help="Provide a compiler flag."
        --hidden
        --multi,
  ]

  compile-analyze-options := [
    cli.Option "dependency-file"
      --help="""
          Write a dependency file ('-' for stdout).
          Requires the '--dependency-format' option.""",
    cli.OptionEnum "dependency-format" ["plain", "ninja"]
      --help="Set the format of the dependency file. For Makefiles use 'ninja'.",
  ]

  compile-run-options := [
    cli.OptionInt "optimization-level" --short-name="O"
        --help="""
            Set the optimization level.
            0: no optimizations,
            1: some optimizations,
            2: more optimizations."""
        --default=1,
    cli.Flag "enable-asserts"
        --help="Enable assertions. Enabled by default for -O0 and -O1.",
    cli.Flag "force" --short-name="f"
        --help="Force compilation even if there were errors (if possible).",
  ]

  run-command := cli.Command "run"
      --help="Runs the given Toit source or snapshot file."
      --options=compile-analyze-run-options + compile-run-options
      --rest=[
        cli.OptionPath "source"
          --help="The source file to run."
          --extensions=[".toit"]
          --required,
        cli.Option "arg"
          --help="Argument to pass to the program."
          --multi,
      ]
      --run=:: compile-or-analyze-or-run --command="run" it
  commands-command.add run-command

  analyze-command := cli.Command "analyze"
      --help="""
        Analyze the given Toit source files."""
      --options=compile-analyze-run-options + compile-analyze-options
      --rest=[
        cli.OptionPath "source"
          --help="The source files to analyze."
          --extensions=[".toit"]
          --required
          --multi,
      ]
      --run=:: compile-or-analyze-or-run --command="analyze" it
  commands-command.add analyze-command

  compile-command := cli.Command "compile"
      --help="""
        Compile the given Toit source file to a Toit binary or a Toit snapshot."""
      --options=compile-analyze-run-options + compile-analyze-options + compile-run-options + [
        cli.Flag "snapshot" --short-name="s"
            --help="Compile to a snapshot instead of a binary.",
        cli.Flag "strip"
            --help="Strip the output of debug information.",
        cli.Option "os"
            --help="Set the target OS for cross compilation."
            --completion=:: | context/cli.CompletionContext | complete-cross-os context,
        cli.Option "arch"
            --help="Set the target architecture for cross compilation."
            --completion=:: | context/cli.CompletionContext | complete-cross-arch context,
        cli.OptionPath "vessels-root"
            --help="Path to the vessels root."
            --directory,
        cli.OptionPath "output" --short-name="o"
            --help="Set the output file name."
            --required,
      ]
      --rest=[
        cli.OptionPath "source"
          --help="The source file to compile."
          --extensions=[".toit"]
          --required,
      ]
      --run=:: compile-or-analyze-or-run --command="compile" it
  commands-command.add compile-command

  commands-command.add pkg.build-command

  tool-command := cli.Command "tool"
      --aliases=["tools"]
      --help="Run a tool."
  commands-command.add tool-command

  tool-command.add toitp.build-command
  tool-command.add firmware.build-command
  tool-command.add assets.build-command
  tool-command.add snapshot-to-image.build-command
  kebabify-cmd := kebabify.build-command --toitc-from-args=toitc-from-args
  tool-command.add kebabify-cmd

  // TODO(florian): add more lsp subcommands, like creating a repro, ...
  tool-lsp-command := cli.Command "lsp"
      --help="Start the language server."
      --run=:: run-lsp-server it
  tool-command.add tool-lsp-command

  esp-command := cli.Command "esp"
      --help="ESP-IDF related commands."
  tool-command.add esp-command

  esp-command.add stacktrace.build-command

  toitdoc-command := toitdoc.build-command
      --toit-from-args=toit-from-args
      --sdk-path-from-args=:: | invocation/cli.Invocation | invocation["sdk-dir"]
  commands-command.add toitdoc-command

  info-command := info.build-command
      --sdk-dir-from-args=:: | invocation/cli.Invocation | invocation["sdk-dir"]
  commands-command.add info-command

  commands-command.add system-message.build-command

  assert:
    // Run the CLI package checks.
    // This makes sure that commands without 'run' functionality have
    // subcommands, or that examples are valid.
    // Otherwise, we could have exceptions when the user tries to run the command
    // or tries to generate its help.
    // If the check fails, it throws an exception.
    root-command.check
    true

  if args.size > 0 and is-toit-source args[0]:
    args = ["run", "--"] + args

  root-command.run args

/**
Resolves the vessels root directory based on the completion $context.

Looks for an explicit --vessels-root option, otherwise derives the vessels
  directory from --sdk-dir (if given) or from the binary's own location.
Returns null if no directory can be determined.
*/
vessels-root-from-context context/cli.CompletionContext -> string?:
  seen := context.seen-options
  vessels-root-values := seen.get "vessels-root"
  if vessels-root-values and not vessels-root-values.is-empty:
    return vessels-root-values.last
  sdk-dir-values := seen.get "sdk-dir"
  sdk-dir/string? := null
  if sdk-dir-values and not sdk-dir-values.is-empty:
    sdk-dir = sdk-dir-values.last
  else:
    our-dir := fs.dirname system.program-path
    sdk-dir = fs.join our-dir ".."
  return fs.join sdk-dir "lib" "toit" "vessels"

/**
Lists the direct subdirectories of $dir.

Returns an empty list if $dir does not exist or cannot be read.
*/
list-subdirs dir/string -> List:
  if not file.is-directory dir: return []
  result := []
  exception := catch:
    stream := directory.DirectoryStream dir
    try:
      while entry := stream.next:
        path := fs.join dir entry
        if file.is-directory path: result.add entry
    finally:
      stream.close
  return result

/**
Completion callback for the `--os` option of `toit compile`.

Suggests the OS names for which vessels are installed.
*/
complete-cross-os context/cli.CompletionContext -> List:
  vessels-root := vessels-root-from-context context
  if not vessels-root: return []
  result := []
  (list-subdirs vessels-root).do: | os/string |
    if os.starts-with context.prefix: result.add (cli.CompletionCandidate os)
  return result

/**
Completion callback for the `--arch` option of `toit compile`.

Suggests architectures for which vessels are installed. If an `--os`
  has already been provided, restricts to its architectures; otherwise
  returns architectures across all known OSes.
*/
complete-cross-arch context/cli.CompletionContext -> List:
  vessels-root := vessels-root-from-context context
  if not vessels-root: return []
  os-values := context.seen-options.get "os"
  os-list/List := ?
  if os-values and not os-values.is-empty:
    os-list = [os-values.last]
  else:
    os-list = list-subdirs vessels-root
  archs := {}
  os-list.do: | os/string |
    (list-subdirs (fs.join vessels-root os)).do: archs.add it
  result := []
  archs.do: | arch/string |
    if arch.starts-with context.prefix: result.add (cli.CompletionCandidate arch)
  return result

tool-path sdk-dir/string? tool/string -> string:
  if system.platform == system.PLATFORM-WINDOWS:
    tool = "$(tool).exe"

  tool-bin-dir/string := ?
  if sdk-dir:
    tool-bin-dir = fs.join sdk-dir "lib" "toit" "bin"
  else:
    our-path := system.program-path
    our-dir := fs.dirname our-path
    tool-bin-dir = fs.join our-dir ".." "lib" "toit" "bin"

  return fs.join tool-bin-dir tool

toit-path sdk-dir/string? -> string:
  // Use ourself as the toit command.
  if sdk-dir:
    result := fs.join sdk-dir "bin" "toit"
    if system.platform == system.PLATFORM-WINDOWS:
      result = "$(result).exe"
    return result
  return system.program-path

run sdk-dir/string? tool/string args/List -> int:
  args = [tool-path sdk-dir tool] + args
  return pipe.run-program args

compile-or-analyze-or-run --command/string invocation/cli.Invocation:
  ui := invocation.cli.ui

  sources/List := ?
  is-snapshot := false
  if command == "analyze":
    sources = invocation["source"]
    sources.do: | source |
      if not file.is-file source: ui.abort "Source file not found: $source"
      source-contents := file.read-contents source
      if snapshot-lib.SnapshotBundle.is-bundle-content source-contents:
        ui.abort "Cannot analyze a snapshot file"
  else:
    source := invocation["source"]
    if not file.is-file source: ui.abort "Source file not found: $source"
    source-contents := file.read-contents source
    is-snapshot = snapshot-lib.SnapshotBundle.is-bundle-content source-contents
    sources = [source]

  args := []

  xflags := invocation["X"]
  if not xflags.is-empty:
    xflags.do:
      args.add "-X$it"

  if invocation["show-package-warnings"]: args.add "--show-package-warnings"
  if invocation["Werror"]: args.add "-Werror"

  if command == "analyze":
    args.add "--analyze"
  else:
    if is-snapshot:
      if invocation.parameters.was-provided "optimization-level":
        ui.abort "Cannot set optimization level for snapshots"
      if invocation.parameters.was-provided "enable-asserts":
        ui.abort "Cannot use --enable-asserts with snapshots"
      if invocation.parameters.was-provided "force":
        ui.abort "Cannot use --force with snapshots"
    else:
      optimization/int := invocation["optimization-level"]
      if not 0 <= optimization <= 2: ui.abort "Invalid optimization level"
      args.add "-O$optimization"

      enable-asserts/bool := optimization < 2
      if invocation.parameters.was-provided "enable-asserts":
        // An explicit --enable-asserts, or --no-enable-asserts, overrides the default.
        if invocation["enable-asserts"]:
          enable-asserts = true
        else:
          enable-asserts = false
      args.add "-Xenable-asserts=$enable-asserts"

      if invocation["force"]:
        args.add "--force"

    if command == "compile":
      if invocation["strip"]:
        args.add "--strip"

      if invocation["os"]:
        args.add "--os"
        args.add invocation["os"]

      if invocation["arch"]:
        args.add "--arch"
        args.add invocation["arch"]

      if invocation["vessels-root"]:
        args.add "--vessels-root"
        args.add invocation["vessels-root"]

      if invocation["snapshot"]:
        args.add "-w"
      else:
        args.add "-o"
      args.add invocation["output"]

  if command == "analyze" or command == "compile":
    if invocation["dependency-file"]:
      args.add "--dependency-file"
      args.add invocation["dependency-file"]
      if invocation["dependency-format"]:
        args.add "--dependency-format"
        args.add invocation["dependency-format"]
      else:
        ui.abort "Missing --dependency-format"
    else if invocation["dependency-format"]:
      ui.abort "Missing --dependency-file"

  if is-snapshot:
    assert: args.is-empty
    // Just in case that's not true and we are running without asserts set the args to empty.
    args = []

  args.add-all sources
  if command == "run":
    args.add-all invocation["arg"]

  exe := command == "run" ? "toit.run" : "toit.compile"
  exit-code := run invocation["sdk-dir"] exe args
  exit exit-code

run-lsp-server invocation/cli.Invocation:
  sdk-dir := invocation["sdk-dir"]
  toit-exe-path/string := toit-path sdk-dir
  // We are not using the cli's Ui class, as it might print on stdout.
  if invocation.cli.ui.level >= Ui.VERBOSE-LEVEL:
    print-on-stderr_ "Using $toit-exe-path as analyzer for the LSP server."
  lsp.main --toit-path-override=toit-exe-path
