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

import .toitp as toitp

main args/List:
  if args.size > 0 and args[0].ends-with ".toit":
    args = ["run", "--"] + args

  // We don't want to add a `--version` option to the root command,
  // as that would make the option available to all subcommands.
  // Fundamentally, getting the version isn't really an option, but a
  // command. The `--version` here is just for convenience, since many
  // tools have it too.
  if args.size == 1 and args[0] == "--version":
    print system.vm-sdk-version
    return

  root-command := cli.Command "toit"
      --help="The Toit command line tool."
      --options=[
        cli.Option "sdk-dir"
            --help="Path to the SDK root."
            --type="dir"
            --hidden,
      ]

  version-command := cli.Command "version"
      --help="Print the version of the Toit SDK."
      --options=[
        // For compatibility with the v1 toit executable. This flag is used by
        // the vscode extension. The v1 executable needed the "short" output to only get
        // the version number. We are ignoring this option, since we always just print the
        // version.
        cli.Option "output" --short-name="o" --hidden
      ]
      --run=:: print system.app-sdk-version
  root-command.add version-command

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
    cli.OptionInt "optimization-level" --short-name="O"
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

  pkg-command := cli.Command "pkg"
      --help="Manage packages."
      --options=[
        cli.Option "project-root"
            --help="Path to the project root that contains the package.{yaml|lock} file."
            --type="dir",
        cli.Option "sdk-version"
            --help="The SDK version to resolve dependencies against.",
        cli.Flag "auto-sync"
            --help="Automatically synchronize registries."
            --default=true,
      ]
  root-command.add pkg-command

  pkg-clean-command := cli.Command "clean"
      --help="""
          Remove unnecessary packages.

          If a package isn't used anymore removes the downloaded files from
          the local package cache.
          """
      --run=:: run-pkg-command ["clean"] [] [] it
  pkg-command.add pkg-clean-command

  pkg-describe-command := cli.Command "describe"
      --help="""
          Generate a description of a package.

          If no 'path' is given, defaults to the current working directory.
          If one argument is given, then it must be a path to a package.
          Otherwise, the first argument is interpreted as the URL to the package, and
          the second argument must be a version.

          A package description is used when publishing packages. It describes the
          package to the outside world. This command extracts a description from
          the given path.

          If the out directory is specified, generates a description file as used
          by registries. The actual description file is generated nested in
          directories to make the description path unique.
          """
      --options=[
        cli.Flag "allow-local-deps"
            --help="Allow local dependencies and don't report them.",
        cli.Flag "disallow-local-deps"
            --help="Always disallow local dependencies and report them.",
        cli.Option "out-dir"
            --help="The directory to write the description file to."
            --type="dir",
        cli.Flag "verbose"
            --help="Show more information.",
      ]
      --rest=[
        cli.Option "path-or-url" --help="A path or URL to a package.",
        cli.Option "version" --help="The version of the package.",
      ]
      --run=:: run-pkg-command ["describe"]
          ["allow-local-deps", "disallow-local-deps", "out-dir", "verbose"]
          ["path-or-url", "version"]
          it
  pkg-command.add pkg-describe-command

  pkg-init-command := cli.Command "init"
      --help="""
          Initialize the current directory as the root of the project.

          Creates a 'package.lock' and 'package.yaml' file in the current directory.

          If the '--project-root' option is used, initialize the given directory as
          the root of the project instead.
          """
      --run=:: run-pkg-command ["init"] [] [] it
  pkg-command.add pkg-init-command

  pkg-install-command := cli.Command "install"
      --aliases=["download", "fetch"]
      --help="""
          Install a package.

          If no 'package' is given, then the command downloads all dependencies.
          If necessary, updates the lock-file. This can happen if the lock file doesn't exist
          yet, or if the lock-file has local path dependencies (which could have their own
          dependencies changed). Recomputation of the dependencies can also be forced by
          providing the '--recompute' flag.

          If a 'package' is given finds the package with the given name or URL and installs it.
          The given 'package' string must uniquely identify a package in the registry.
          It is matched against all package names, and URLs. For the names, a package is considered
          a match if the string is equal. For URLs it is a match if the string is a complete match, or
          the '/' + string is a suffix of the URL.

          The 'package' may be suffixed by a version with a '@' separating the package name and
          the version. The version doesn't need to be complete. For example 'foo@2' installs
          the package foo with the highest version satisfying '2.0.0 <= version < 3.0.0'.
          Note: the version constraint in the package.yaml is set to accept semver compatible
          versions. If necessary, modify the constraint in that file.

          Installed packages can be imported by their prefix. By default the prefix is their
          name, but the '--prefix' argument can override the default.

          If the '--local' flag is used, then the 'package' argument is interpreted as
          a local path to a package directory. Note that published packages may not
          contain local packages.
          """
      --options=[
        cli.Flag "local" --help="Treat the package argument as a local path.",
        cli.Option "prefix" --help="The prefix that needs to be used in 'import' clauses.",
        cli.Flag "recompute" --help="Recompute the dependencies.",
      ]
      --rest=[
        cli.Option "package" --help="The package to install." --multi,
      ]
      --examples=[
        cli.Example "Install all dependencies."
            --arguments="",
        cli.Example """
            Install the package named 'morse'.
            The prefix of the package is 'morse' (the package name). The package can be
            import with 'import morse', if the package has a file 'src/morse.toit'.
            Assumes that 'morse' uniquely identifies the 'morse' package.
            """
            --arguments="morse",
        cli.Example """
            Install the package 'morse' with an alternative prefix 'alt-morse'.
            Programs would import the package with 'import alt-morse'.
            """
            --arguments="morse --prefix=alt-morse",
        cli.Example "Install the version 1.0.0 of the package 'morse'."
            --arguments="morse@1.0.0",
        cli.Example """
            Install the package 'morse' by URL to disambiguate.
            The longer the URL the more likely it is to be unique.
            Programs would import the package with 'import morse'.
            """
            --arguments="toitware/toit-morse",
        cli.Example """
            Install the package 'morse' by complete URL.
            This guarantees that the package is uniquely identified.
            """
            --arguments="github.com/toitware/toit-morse",
        cli.Example """
            Install the package 'morse' by URL with a given prefix
            Programs would import the package with 'import alt-morse'.
            """
            --arguments="toitware/toit-morse --prefix=alt-morse",
        cli.Example """
            Install a local package folder by path.
            By default the name in the package's package.yaml is used as the prefix.
            """
            --arguments="--local ../my_other_package",
        cli.Example """
            Install a local package folder by path with a given prefix.
            """
            --arguments="--local ../my_other_package --prefix=other",
      ]
      --run=:: run-pkg-command ["install"] ["local", "prefix", "recompute"] ["package"] it
  pkg-command.add pkg-install-command

  pkg-list-command := cli.Command "list"
      --help="""
          List all packages.

          If no argument is given, lists all available packages.
          If an argument is given, it must point to a registry path. In that case
          only the packages from that registry are listed.
          """
      --options=[
        cli.OptionEnum "output" ["list", "json"]
            --help="The output format."
            --default="list",
        cli.Flag "verbose"
            --help="Show more information.",
      ]
      --rest=[
        cli.Option "registry" --help="The registry to list packages from.",
      ]
      --run=:: run-pkg-command ["list"] ["output", "verbose"] ["registry"] it
  pkg-command.add pkg-list-command

  pkg-registry-command := cli.Command "registry"
      --help="""
          Manage registries.

          Registries are used to find packages. They are a collection of packages
          that can be installed. The default registry is the Toit registry.
          """
  pkg-command.add pkg-registry-command

  pkg-registry-add-command := cli.Command "add"
      --help="""
          Add a registry.

          Adds a registry to the list of registries. The registry is identified by a name
          and a URL. The URL must point to a valid registry.

          The 'name' of the registry must not be used yet.
          """
      --options=[
        cli.Flag "local" --help="The registry is local.",
      ]
      --rest=[
        cli.Option "name" --help="The name of the registry." --required,
        cli.Option "url" --help="The URL of the registry." --required,
      ]
      --examples=[
        cli.Example "Add the Toit registry."
            --arguments="toit github.com/toitware/registry",
      ]
      --run=:: run-pkg-command ["registry", "add"] ["local"] ["name", "url"] it
  pkg-registry-command.add pkg-registry-add-command

  pkg-registry-list-command := cli.Command "list"
      --help="""
          List all registries.

          Lists all registries that are known to the system.
          """
      --run=:: run-pkg-command ["registry", "list"] [] [] it
  pkg-registry-command.add pkg-registry-list-command

  pkg-registry-remove-command := cli.Command "remove"
      --help="""
          Remove a registry.

          Removes a registry from the list of registries. The registry is identified by a name.
          """
      --rest=[
        cli.Option "name" --help="The name of the registry." --required,
      ]
      --run=:: run-pkg-command ["registry", "remove"] [] ["name"] it
  pkg-registry-command.add pkg-registry-remove-command

  pkg-registry-sync-command := cli.Command "sync"
      --help="""
          Synchronize registries.

          If no argument is given, synchronize all registries.
          If an argument is given, it must point to a registry path. In that case
          only that registry is synchronized.
          """
      --options=[
        cli.Flag "clear-cache" --help="Clear the cache before syncing.",
      ]
      --rest=[
        cli.Option "name" --help="The name of the registry.",
      ]
      --run=:: run-pkg-command ["registry", "sync"] ["clear-cache"] ["name"] it
  pkg-registry-command.add pkg-registry-sync-command

  pkg-search-command := cli.Command "search"
      --help="""
          Search for packages.

          Search for a package in the registries. The search string is matched against
          the package names, descriptions and URLs.
          """
      --options=[
        cli.Flag "verbose"
            --help="Show more information.",
      ]
      --rest=[
        cli.Option "needle" --help="The search string." --required,
      ]
      --run=:: run-pkg-command ["search"] ["verbose"] ["needle"] it
  pkg-command.add pkg-search-command

  pkg-sync-command := cli.Command "sync"
      --help="""
          Synchronizes all registries.

          This is an alias for 'toit pkg registry sync'.
          """
      --options=[
        cli.Flag "clear-cache" --help="Clear the cache before syncing.",
      ]
      --run=:: run-pkg-command ["sync"] ["clear-cache"] [] it
  pkg-command.add pkg-sync-command

  pkg-uninstall-command := cli.Command "uninstall"
      --aliases=["remove"]
      --help="""
          Uninstall a package.

          Remove the package of the given name from the project.
          The downloaded code is not automatically deleted.
          """
      --rest=[
        cli.Option "prefix" --help="The prefix of the package that should be uninstalled." --required,
      ]
      --run=:: run-pkg-command ["uninstall"] [] ["prefix"] it
  pkg-command.add pkg-uninstall-command

  pkg-update-command := cli.Command "update"
      --help="""
          Update all packages to their newest compatible version.

          Uses semantic versioning to find the highest compatible version of
          each dependency.
          """
      --run=:: run-pkg-command ["update"] [] [] it
  pkg-command.add pkg-update-command

  root-command.add toitp.build-command

  root-command.run args

error message/string:
  print message
  exit 1

bin-dir sdk-dir/string? -> string:
  if sdk-dir:
    return fs.join sdk-dir "bin"
  our-path := system.program-path
  return fs.dirname our-path

run sdk-dir/string? tool/string args/List:
  if system.platform == system.PLATFORM-WINDOWS:
    tool = "$(tool).exe"
  tool-path := fs.join (bin-dir sdk-dir) tool
  args = [tool-path] + args
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
    if parsed["optimization-level"]:
      optimization/int := parsed["optimization-level"]
      if not 0 <= optimization <= 2: error "Invalid optimization level"
      args.add "-O$optimization"

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

run-pkg-command command/List arg-names/List rest-args/List parsed/cli.Parsed:
  auto-sync := parsed["auto-sync"]
  project-root := parsed["project-root"]
  sdk-version := parsed["sdk-version"]

  args := command.copy
  if auto-sync != null: args.add "--auto-sync=$auto-sync"
  if project-root: args.add "--project-root=$project-root"
  if sdk-version: args.add "--sdk-version=$sdk-version"
  arg-names.do:
    if parsed[it] != null: args.add-all ["--$it", parsed[it]]
  rest-args.do:
    if parsed[it] != null:
      rest-arg := parsed[it]
      if rest-arg is List:
        args.add-all rest-arg
      else:
        args.add parsed[it]

  run parsed["sdk-dir"] "toit.pkg" args
