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
import system

build-command --sdk-dir-from-args/Lambda -> cli.Command:
  cmd := cli.Command "info"
      --help="Show information about the SDK and packages."

  sdk-command := cli.Command "sdk"
      --help="""
          Show SDK information.

          Prints the SDK version, paths, and platform information.

          Use '--output-format=json' for machine-readable output. For example,
          to extract just the SDK path:

            toit info sdk --output-format=json | jq -r '.path'
          """
      --run=:: info-sdk it --sdk-dir-from-args=sdk-dir-from-args
  cmd.add sdk-command

  pkg-command := cli.Command "pkg"
      --help="""
          Show package information for the current project.

          Prints the package prefixes and their resolved paths.
          Use --package to show a specific package's imports instead of the
          project's.

          Use '--output-format=json' for machine-readable output. For example,
          to get the path to a specific package:

            toit info pkg --output-format=json | jq -r '.packages.http.path'

          To list all available prefixes:

            toit info pkg --output-format=json | jq -r '.packages | keys[]'
          """
      --options=[
        cli.OptionPath "project-root"
            --help="Path to the project root that contains the package.lock file."
            --directory,
        cli.Option "package"
            --help="Show imports from a specific package's perspective.",
      ]
      --run=:: info-pkg it
  cmd.add pkg-command

  return cmd

info-sdk invocation/cli.Invocation --sdk-dir-from-args/Lambda:
  ui := invocation.cli.ui
  sdk-dir/string? := sdk-dir-from-args.call invocation
  if not sdk-dir:
    our-path := system.program-path
    our-dir := fs.dirname our-path
    sdk-dir = fs.to-absolute (fs.join our-dir "..")

  result := {
    "version": system.vm-sdk-version,
    "path": sdk-dir,
    "lib-path": fs.join sdk-dir "lib",
    "bin-path": fs.join sdk-dir "bin",
    "platform": system.platform,
  }
  // TODO(florian): Use human-friendly header keys (e.g. "Version", "Lib path")
  //   once the CLI package supports a --header parameter on emit-map.
  ui.emit-map --result result

info-pkg invocation/cli.Invocation:
  ui := invocation.cli.ui
  project-root := invocation["project-root"]
  if not project-root: project-root = "."
  project-root = fs.to-absolute project-root

  lock-path := fs.join project-root "package.lock"
  if not file.is-file lock-path:
    ui.abort "No package.lock file found in '$project-root'."

  lock-content/Map := (yaml.decode (file.read-contents lock-path)) or {:}
  sdk-constraint := lock-content.get "sdk"
  top-prefixes/Map := lock-content.get "prefixes" --if-absent=: {:}
  all-packages/Map := lock-content.get "packages" --if-absent=: {:}

  requested-package := invocation["package"]
  if requested-package:
    // Show a specific package's imports.
    package-id := top-prefixes.get requested-package
    if not package-id:
      ui.abort "Unknown prefix '$requested-package'. Available prefixes: $(top-prefixes.keys.join ", ")."

    package-entry/Map := all-packages.get package-id
        --if-absent=: ui.abort "Package '$package-id' not found in lock file."
    package-prefixes/Map := package-entry.get "prefixes" --if-absent=: {:}

    packages := {:}
    package-prefixes.do: | prefix/string dep-id/string |
      packages[prefix] = resolve-package-entry_ dep-id all-packages project-root

    result := {
      "package": requested-package,
      "packages": packages,
    }
    ui.emit-map --result result
    return

  // Default: show project's direct imports.
  packages := {:}
  top-prefixes.do: | prefix/string package-id/string |
    packages[prefix] = resolve-package-entry_ package-id all-packages project-root

  result := {
    "project-root": project-root,
    "sdk-constraint": sdk-constraint,
    "packages": packages,
  }
  ui.emit-map --result result

resolve-package-entry_ package-id/string all-packages/Map project-root/string -> Map:
  entry/Map := all-packages.get package-id --if-absent=: {:}
  result := {:}

  url := entry.get "url"
  version := entry.get "version"
  local-path := entry.get "path"

  if url:
    result["url"] = url
  if version:
    result["version"] = version

  if local-path:
    result["path"] = fs.to-absolute (fs.join project-root local-path "src")
  else if url and version:
    cache-path := fs.join project-root ".packages" (escape-path_ "$url/$version") "src"
    result["path"] = fs.to-absolute cache-path

  return result

/**
Escapes the given $path so it's valid on Windows.
On non-Windows platforms this is a no-op.
*/
escape-path_ path/string -> string:
  if system.platform != system.PLATFORM-WINDOWS:
    return path
  escaped-path := path.replace --all "#" "##"
  [ '<', '>', ':', '"', '|', '?', '*', '\\' ].do:
    escaped-path = escaped-path.replace --all
        (string.from-rune it)
        "#$(it.stringify 16)"
  return escaped-path
