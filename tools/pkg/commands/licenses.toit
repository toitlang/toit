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
import encoding.yaml
import fs
import host.file
import io
import system

import ..pkg
import ..project
import ..project.lock
import ..project.specification
import ..semantic-version

import .base_

class LicenseOverride_:
  url/string
  version/string
  path/string
  used/bool := false

  constructor --.url --.version --.path:

class LicenseEntry_:
  name/string
  source/string
  license-path/string
  license-name/string
  version/string?
  revision/string?
  is-override/bool

  constructor
      --.name
      --.source
      --.license-path
      --.license-name
      --.version
      --.revision
      --.is-override/bool=false:

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
    overrides := load-overrides_
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
        version := repository-package.version.to-string
        override := find-override_
            overrides
            repository-package.url
            version
        continue.map LicenseEntry_
            --name=specification.name
            --source=repository-package.url
            --license-path=(override
                ? fs.join project.root override.path
                : fs.join specification.root-dir "LICENSE")
            --license-name=(override ? override.path : "LICENSE")
            --version=version
            --revision=repository-package.ref-hash
            --is-override=override != null

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

    overrides.do: | override/LicenseOverride_ |
      if not override.used:
        ui.abort """
            License override for '$override.url@$override.version' does not match
              any package in package.lock."""

    dependency-entries.sort --in-place: | a/LicenseEntry_ b/LicenseEntry_ |
      a.compare-to b
    entries.add-all dependency-entries
    if include-sdk: entries.add sdk-license-entry_
    return entries

  load-overrides_ -> List:
    config-path := fs.join project.root LICENSES-FILE
    if not file.is-file config-path: return []

    decoded := yaml.decode (file.read-contents config-path) --if-error=: | error/string |
      ui.abort "Invalid $LICENSES-FILE content: $error."
    if decoded is not Map:
      ui.abort "Invalid $LICENSES-FILE content: not a map."
    config := decoded as Map
    config.do --keys: | key/string |
      if key != OVERRIDES-KEY:
        ui.abort "Invalid $LICENSES-FILE content: unknown key '$key'."

    raw-overrides := config.get OVERRIDES-KEY
    if raw-overrides == null: return []
    if raw-overrides is not List:
      ui.abort "Invalid $LICENSES-FILE content: '$OVERRIDES-KEY' is not a list."

    result := []
    seen := {}
    (raw-overrides as List).do: | raw-override |
      if raw-override is not Map:
        ui.abort "Invalid license override: not a map."
      map := raw-override as Map
      map.do --keys: | key/string |
        if not [URL-KEY, VERSION-KEY, PATH-KEY].contains key:
          ui.abort "Invalid license override: unknown key '$key'."

      url := required-override-string_ map URL-KEY
      version := required-override-string_ map VERSION-KEY
      path := required-override-string_ map PATH-KEY
      parsed-version := SemanticVersion.parse version --on-error=: | error/string |
        ui.abort "Invalid license override version '$version': $error."
      version = parsed-version.to-string
      if not fs.is-relative path:
        ui.abort "Invalid license override path '$path': must be relative."

      key := "$url\n$version"
      if seen.contains key:
        ui.abort "Duplicate license override for '$url@$version'."
      seen.add key
      result.add (LicenseOverride_ --url=url --version=version --path=path)
    return result

  required-override-string_ map/Map key/string -> string:
    value := map.get key
    if value is not string or value == "":
      ui.abort "Invalid license override: '$key' must be a non-empty string."
    return value

  find-override_ overrides/List url/string version/string -> LicenseOverride_?:
    overrides.do: | override/LicenseOverride_ |
      if override.url == url and override.version == version:
        override.used = true
        return override
    return null

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
      // This fallback is only for development when running
      // `toit tools/toit.toit`.
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

  write-entry_ output/io.Writer entry/LicenseEntry_:
    if not file.is-file entry.license-path:
      if entry.is-override:
        error """
            License override for package '$entry.name' does not exist at
              '$entry.license-path'."""
      error "Package '$entry.name' has no top-level LICENSE file at '$entry.license-path'."

    output.write """
        ================================================================================
        Package: $entry.name
        Source: $entry.source
        """
    if entry.version: output.write "Version: $entry.version\n"
    if entry.revision: output.write "Revision: $entry.revision\n"
    output.write "$(entry.is-override ? "License override" : "License file"): $entry.license-name\n"
    output.write "================================================================================\n"
    license-content := file.read-contents entry.license-path
    output.write license-content
    if license-content.is-empty or license-content.last != '\n':
      output.write "\n"
    output.write "\n"

  static OUTPUT-OPTION ::= "output"
  static INCLUDE-SDK-OPTION ::= "include-sdk"
  static LICENSES-FILE ::= "licenses.yaml"
  static OVERRIDES-KEY ::= "overrides"
  static URL-KEY ::= "url"
  static VERSION-KEY ::= "version"
  static PATH-KEY ::= "path"

  static CLI-COMMAND ::=
      cli.Command "licenses"
          --help="""
              Collects the top-level LICENSE files of a project and its dependencies.

              The packages are taken from package.lock. Missing packages are downloaded
                before their licenses are collected.

              Repository-package licenses can be overridden in a root-level
                licenses.yaml file:

                overrides:
                  - url: github.com/example/package
                    version: 1.2.3
                    path: licenses/example-package-1.2.3.LICENSE

              URLs and versions must exactly match package.lock. Override paths are
                relative to the project root.
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
