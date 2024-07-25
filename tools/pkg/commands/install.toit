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
import host.file
import fs

import ..error
import ..project
import ..project.package
import ..registry

import .utils_

class InstallCommand:
  static PREFIX    ::= "prefix"
  static LOCAL     ::= "local"
  static RECOMPUTE ::= "recompute"
  static REST      ::= "package"

  prefix/string? := null
  package/string?
  local/bool
  recompute/bool
  project/Project

  constructor parsed/cli.Parsed:
    prefix = parsed[PREFIX]

    package = parsed[REST]
    local = parsed[LOCAL]
    recompute = parsed[RECOMPUTE]

    if not package and local:
      error "Can not specify local without a package"

    if not package and prefix:
      error "Can not specify a prefix without a package."

    if package and recompute:
      error "Recompute can only be specified with no other arguments."

    config := project-configuration-from-cli parsed
    config.verify

    project = Project config

  execute:
    if not package:
      project.install
    else if not local:
      execute-remote
    else:
      execute-local

  execute-remote:
    remote-package := registries.search package
    if not prefix: prefix = remote-package.name

    if project.package-file.has-package prefix:
      error "Project already has a package with name '$prefix'."

    project.install-remote prefix remote-package

  execute-local:
    package-file-name := "$package/$PackageFile.FILE_NAME"
    src-directory := "$package/src"
    if not file.is-file package-file-name:
      error "Path supplied in package argument is an invalid local package, missing $package-file-name."

    if not file.is-directory src-directory:
      error "Path supplied in package argument is an invalid local package, missing $src-directory."

    package-file := ExternalPackageFile --dir=(fs.to-absolute package)
    if not prefix: prefix = package-file.name

    project.install-local prefix package

  static CLI-COMMAND ::=
      cli.Command "install"
          --help="""
              Installs a package in the current project, or downloads all dependencies.

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
          --examples=[
              cli.Example --arguments="morse"
                  """
                  Install package named 'morse'. The installed name is 'morse' (the package name).
                  Programs would import this package with 'import morse.morse'
                    which can be shortened to 'import morse'.
                  """,
              cli.Example --arguments="morse --prefix=alt_morse"
                  """
                  Install the package 'morse' with an alternative prefix.
                  Programs would use this package with 'import alt_morse.morse'.
                  """,
              cli.Example --arguments="morse@1.0.0"
                  """
                  Install the version 1.0.0 of the package 'morse'.
                  """,
              cli.Example --arguments="toitware/toit-morse"
                  """
                  Install the package 'morse' by URL (to disambiguate).
                  Programs would import this package with 'import morse'.
                  """,
              cli.Example --arguments="github.com/toitware/toit-morse"
                  """
                  Install the package 'morse' by an even longer URL (to disambiguate). The longer the URL
                    the less likely a conflict.
                  """,
              cli.Example --arguments="toitware/toit-morse --prefix=alt_morse"
                  """
                  Install the package 'morse' by URL with a given prefix.
                  Programs would use this package with 'import alt_morse.morse'.
                  """,
              cli.Example --arguments="--local ../my_other_package"
                  """
                  Install a local package folder by path.
                  By default the name in the package's package.yaml is used as prefix.
                  """,
              cli.Example --arguments="--local submodules/my_other_package --prefix=other"
                  """
                  Install a local package folder by path with a specific prefix.
                  Programs would use this package with 'import other'.
                  """,
          ]
          --rest=[
              cli.Option REST
          ]
          --options=[
              cli.Flag LOCAL
                  --help="Treat package argument as local path."
                  --default=false,
              cli.Option PREFIX
                  --help="The prefix used for the 'import' clause.",
              cli.Flag RECOMPUTE
                  --help="Recompute dependencies."
                  --default=false
          ]
          --run=:: (InstallCommand it).execute
