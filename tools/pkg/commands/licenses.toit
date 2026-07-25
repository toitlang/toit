// Copyright (C) 2026 Toit contributors.
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
import io
import system

import ..pkg
import ..project
import ..project.lock
import ..project.specification

import .base_

class LicenseEntry_:
  name/string
  source/string
  license-path/string
  license-name/string
  version/string?
  revision/string?

  constructor
      --.name
      --.source
      --.license-path
      --.license-name
      --.version
      --.revision:

  compare-to other/LicenseEntry_ -> int:
    return source.compare-to other.source --if-equal=:
      name.compare-to other.name --if-equal=:
        (version or "").compare-to (other.version or "")

class LicensesCommand extends PkgProjectCommand:
  output-path/string
  include-sdk/bool

  constructor invocation/cli.Invocation:
    output-path = invocation[OUTPUT-OPTION]
    include-sdk = invocation[INCLUDE-SDK-OPTION]
    super invocation

  execute:
    project.install --no-recompute --registries=registries

    entries := collect-entries_
    output := io.Buffer
    entries.do: write-entry_ output it
    file.write-contents output.bytes --path=output-path
    ui.emit --info "Wrote licenses for $entries.size packages to '$output-path'."

  collect-entries_ -> List:
    root-specification := project.specification
    root-name := root-specification.has-name
        ? root-specification.name
        : fs.basename project.root
    entries := [
      LicenseEntry_
          --name=root-name
          --source="."
          --license-path=(fs.join project.root "LICENSE")
          --license-name="LICENSE"
          --version=null
          --revision=null,
    ]

    lock-file := project.lock-file
    if not lock-file: return entries

    dependency-entries := lock-file.packages.map: | package/Package |
      if package is RepositoryPackage:
        repository-package := package as RepositoryPackage
        specification := project.load-package-specification
            repository-package.url
            repository-package.version
        continue.map LicenseEntry_
            --name=specification.name
            --source=repository-package.url
            --license-path=(fs.join specification.root-dir "LICENSE")
            --license-name="LICENSE"
            --version=repository-package.version.to-string
            --revision=repository-package.ref-hash

      local-package := package as LocalPackage
      root := root-specification.absolute-path-for-dependency local-package.path
      name := local-package.name or fs.basename root
      specification-path := fs.join root Specification.FILE-NAME
      if file.is-file specification-path:
        specification := project.load-local-specification local-package.path
        if specification.has-name: name = specification.name
      continue.map LicenseEntry_
          --name=name
          --source=local-package.path
          --license-path=(fs.join root "LICENSE")
          --license-name="LICENSE"
          --version=null
          --revision=null

    dependency-entries.sort --in-place: | a/LicenseEntry_ b/LicenseEntry_ |
      a.compare-to b
    entries.add-all dependency-entries
    if include-sdk: entries.add sdk-license-entry_
    return entries

  sdk-license-entry_ -> LicenseEntry_:
    program-dir := fs.dirname system.program-path
    candidates := [
      fs.to-absolute
          fs.join [
            program-dir,
            "..",
            "..",
            "..",
            "lib",
            "toit",
            "SDK-LICENSES",
          ],
      fs.to-absolute
          fs.join [program-dir, "..", "..", "debian", "copyright"],
    ]
    license-path/string? := null
    candidates.do: | candidate/string |
      if not license-path and file.is-file candidate: license-path = candidate
    if not license-path:
      error """
          Unable to find the Toit SDK license information.
          Looked for: $(candidates.join ", ")"""

    return LicenseEntry_
        --name="Toit SDK"
        --source="https://github.com/toitlang/toit"
        --license-path=license-path
        --license-name="SDK-LICENSES"
        --version=system.vm-sdk-version
        --revision=null

  write-entry_ output/io.Buffer entry/LicenseEntry_:
    if not file.is-file entry.license-path:
      error "Package '$entry.name' has no top-level LICENSE file at '$entry.license-path'."

    output.write """
        ================================================================================
        Package: $entry.name
        Source: $entry.source
        """
    if entry.version: output.write "Version: $entry.version\n"
    if entry.revision: output.write "Revision: $entry.revision\n"
    output.write "License file: $entry.license-name\n"
    output.write "================================================================================\n"
    license-content := file.read-contents entry.license-path
    output.write license-content
    if license-content.is-empty or license-content.last != '\n':
      output.write "\n"
    output.write "\n"

  static OUTPUT-OPTION ::= "output"
  static INCLUDE-SDK-OPTION ::= "include-sdk"

  static CLI-COMMAND ::=
      cli.Command "licenses"
          --help="""
              Collects the top-level LICENSE files of a project and its dependencies.

              The packages are taken from package.lock. Missing packages are downloaded
                before their licenses are collected.
              """
          --options=[
            cli.Flag INCLUDE-SDK-OPTION
                --help="Include the licenses of the Toit SDK."
                --default=true,
            cli.OptionPath OUTPUT-OPTION
                --short-name="o"
                --help="Write the collected licenses to this file."
                --required,
          ]
          --run=:: (LicensesCommand it).execute
