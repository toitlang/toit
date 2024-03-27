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
import fs
import host.file
import host.pipe
import system

main args/List:
  if args.size > 0 and args[0].ends-with ".toit":
    args = ["run", "--"] + args

  root-command := cli.Command "toit"
      --help="The Toit command line tool."
      --options=[
        cli.Option "sdk-dir"
            --help="Path to the SDK root."
            --type="dir"
            --hidden,
      ]

  compile-analyze-run-options := [
    cli.Flag "show-package-warnings"
        --help="Show warnings from packages.",
    cli.Flag "Werror" --short-name="Werror"
        --help="Treat warnings as errors.",
    cli.Option "project-root"
        --help="Path to the project root. Any package.lock file must be in that folder."
        --type="dir",
    cli.Option "X" --short-name="X"
        --help="Provide a compiler flag."
        --hidden
        --multi,
  ]

  compile-run-options := [
    cli.OptionInt "optimization" --short-name="O"
        --help="""
            Set the optimization level.
            0 is no optimization,
            1 is some optimization,
            2 is more optimization."""
        --default=1,
    cli.Flag "force" --short-name="f"
        --help="Force compilation even if there were errors (if possible).",
  ]

  run-command := cli.Command "run"
      --help="Runs the given Toit source or snapshot file."
      --options=compile-analyze-run-options + compile-run-options
      --rest=[
        cli.Option "source"
          --help="The source file to run."
          --required,
        cli.Option "arg"
          --help="Argument to pass to the program."
          --multi,
      ]
      --run=:: compile-or-analyze-or-run --command="run" it
  root-command.add run-command

  analyze-command := cli.Command "analyze"
      --help="""
        Analyze the given Toit source file."""
      --options=compile-analyze-run-options
      --rest=[
        cli.Option "source"
          --help="The source file to analyze."
          --required,
      ]
      --run=:: compile-or-analyze-or-run --command="analyze" it
  root-command.add analyze-command

  compile-command := cli.Command "compile"
      --help="""
        Compile the given Toit source file to a Toit binary or a Toit snapshot."""
      --options=compile-analyze-run-options + compile-run-options + [
        cli.Flag "snapshot" --short-name="s"
            --help="Compile to a snapshot instead of a binary.",
        cli.Option "dependency-file"
            --help="""
                Write a dependency file ('-' for stdout).
                Requires the '--dependency-format' option.""",
        cli.OptionEnum "dependency-format" ["plain", "ninja"]
            --help="Set the format of the dependency file.",
        cli.Flag "strip"
            --help="Strip the output of debug information.",
        cli.Option "os"
            // TODO(florian): find valid values depending on which vessels exist.
            --help="Set the target OS for cross compilation.",
        cli.Option "arch"
            // TODO(florian): find valid values depending on which vessels exist.
            --help="Set the target architecture for cross compilation.",
        cli.Option "output" --short-name="o"
            --help="Set the output file name."
            --required,
      ]
      --rest=[
        cli.Option "source"
          --help="The source file to compile."
          --required,
      ]
      --run=:: compile-or-analyze-or-run --command="compile" it
  root-command.add compile-command

  lsp-command := cli.Command "lsp"
      --help="Start the language server."
      --run=:: run-lsp-server it
  root-command.add lsp-command

  root-command.run args

error message/string:
  print message
  exit 1

bin-dir sdk-dir/string? -> string:
  if sdk-dir:
    return fs.join sdk-dir "bin"
  else:
    our-path := system.program-path
    return fs.dirname our-path

run sdk-dir/string? tool/string args/List:
  if system.platform == system.PLATFORM-WINDOWS:
    tool = "$(tool).exe"
  tool-path := fs.join (bin-dir sdk-dir) tool
  args = [tool-path] + args
  print "running: $args"
  pipe.run-program args

compile-or-analyze-or-run --command/string parsed/cli.Parsed:
  args := []

  xflags := parsed["X"]
  if not xflags.is-empty:
    xflags.do:
      args.add "-X$it"

  if parsed["show-package-warnings"]: args.add "--show-package-warnings"
  if parsed["Werror"]: args.add "-Werror"

  if command == "analyze":
    args.add "--analyze"
  else:
    if parsed["optimization"]:
      optimization/int := parsed["optimization"]
      if not 0 <= optimization <= 2: error "Invalid optimization level"
      args.add "-O$parsed["optimization"]"

    if parsed["force"]: args.add "--force"

    if command == "compile":
      if parsed["dependency-file"]:
        args.add "--dependency-file"
        args.add parsed["dependency-file"]
        if parsed["dependency-format"]:
          args.add "--dependency-format"
          args.add parsed["dependency-format"]
        else:
          error "Missing --dependency-format"

      if parsed["strip"]: args.add "--strip"

      if parsed["os"]:
        args.add "--os"
        args.add parsed["os"]

      if parsed["arch"]:
        args.add "--arch"
        args.add parsed["arch"]

      if parsed["snapshot"]:
        args.add "-w"
      else:
        args.add "-o"
      args.add parsed["output"]

  args.add parsed["source"]
  if command == "run":
    args.add-all parsed["arg"]

  exe := command == "run" ? "toit.run" : "toit.compile"
  run parsed["sdk-dir"] exe args

run-lsp-server parsed/cli.Parsed:
  sdk-dir := parsed["sdk-dir"]
  args := [
    "--toitc", fs.join (bin-dir sdk-dir) "toitc",
  ]
  run sdk-dir "toit.lsp" args
