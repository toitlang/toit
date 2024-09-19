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
import encoding.json
import fs
import host.directory
import host.file

import .lsp-exports as lsp
import .src.builder show DocsBuilder

main args/List:
  cmd := cli.Command "toitdoc"
      --help="""
        Generate documentation from Toit source code.

        Generates a JSON file that can be served with the toitdocs web-app located
        at https://github.com/toitware/web-toitdocs.
        """
      --options=[
        cli.Option "output"
            --short-name="o"
            --help="Output JSON file."
            --type="file"
            --required,
        cli.Option "pkg-name"
            --help="Name of the package.",
        cli.Option "version"
            --help="Version of the package, or application.",
        cli.Option "root-path"
            --type="dir"
            --help="Root path to build paths from.",
        cli.Option "toitc"
            --type="file"
            --help="Path to the Toit compiler."
            --required,
        cli.Option "sdk"
            --type="dir"
            --help="SDK path."
            --hidden,
        cli.Flag "exclude-sdk"
            --help="Exclude SDK libraries from the documentation."
            --default=false,
        cli.Flag "exclude-pkgs"
            --help="Exclude other packages from the documentation."
            --default=false,
        cli.Flag "include-private"
            --help="Include private elements in the documentation."
            --default=false,
      ]
      --rest=[
        cli.Option "source"
            --type="file|dir"
            --required
            --multi,
      ]
      --run=:: toitdoc it
  cmd.run args

collect-files sources/List -> List:
  pending := Deque
  pending.add-all sources

  result := []
  while not pending.is-empty:
    source := pending.remove-first
    if file.is-directory source:
      stream := directory.DirectoryStream source
      while file-name := stream.next:
        pending.add "$source/$file-name"
    else if file.is-file source and source.ends-with ".toit":
      result.add source
  return result

/**
Computes the project URI for the given $uris.

We assume that the shortest project-uri of all the given uris is the project-uri.
*/
compute-project-uri uris/List --documents/lsp.Documents -> string:
  project-uri := null
  uris.do: | uri/string |
    current-project-uri := documents.project-uri-for --uri=uri
    if not project-uri or current-project-uri.size < project-uri.size:
      project-uri = current-project-uri
  return project-uri

/**
Warn the user if the given uris are in multiple projects.
*/
warn-if-not-one-project documents/lsp.Documents -> none:
  project-uris := documents.all-project-uris
  if project-uris.is-empty:
    throw "No project found."

  if project-uris.size > 1:
    paths := project-uris.map: | it | lsp.to-path it
    print "Warning: more than one project found: $(paths.join ", ")"

eval-symlinks path/string -> string:
  parts := fs.split path
  result := ""
  parts.do: | part/string |
    if result == "":
      result = part
    else:
      result = fs.join result part
    stat := file.stat result
    type := stat[file.ST-TYPE]
    if type == file.SYMBOLIC-LINK or type == file.DIRECTORY-SYMBOLIC-LINK:
      result = file.readlink result

  return result

compute-sdk-path --sdk-path/string? --toitc/string? -> string:
  if sdk-path:
    if not file.is-directory sdk-path:
      print "SDK not found at $sdk-path"
      exit 1
    if not fs.is-absolute sdk-path:
      sdk-path = fs.to-absolute sdk-path
    return sdk-path

  toitc = eval-symlinks toitc

  // Try first with the directory of the toitc.
  sdk-path = fs.dirname toitc
  lib-dir := fs.join sdk-path "lib"
  if file.is-directory lib-dir: return sdk-path
  // Try "..".
  sdk-path = fs.join sdk-path ".."
  lib-dir = fs.join sdk-path "lib"
  if file.is-directory lib-dir: return sdk-path
  throw "Couldn't determine SDK path"

toitdoc parsed/cli.Parsed:
  output := parsed["output"]
  pkg-name := parsed["pkg-name"]
  version := parsed["version"]
  root-path := parsed["root-path"]
  toitc := parsed["toitc"]
  sdk-path := parsed["sdk"]
  exclude-sdk := parsed["exclude-sdk"]
  exclude-pkgs := parsed["exclude-pkgs"]
  include-private := parsed["include-private"]
  sources := parsed["source"]

  if not root-path:
    root-path = directory.cwd

  if toitc:
    if not file.is-file toitc:
      print "Toit compiler not found at $toitc"
      exit 1
    if not fs.is-absolute toitc:
      toitc = fs.to-absolute toitc

  sdk-path = compute-sdk-path --sdk-path=sdk-path --toitc=toitc
  sdk-uri := lsp.to-uri sdk-path
  if not sdk-uri.ends-with "/": sdk-uri = "$sdk-uri/"

  paths := collect-files sources
  uris := paths.map: lsp.to-uri (fs.to-absolute it)

  documents := lsp.compute-summaries --uris=uris --toitc=toitc --sdk-path=sdk-path
  warn-if-not-one-project documents
  project-uri := compute-project-uri uris --documents=documents
  summaries := (documents.analyzed-documents-for --project-uri=project-uri).summaries

  builder := DocsBuilder summaries
      --project-uri=project-uri
      --root-path=root-path
      --sdk-uri=sdk-uri
      --pkg-name=pkg-name
      --version=version
      --exclude-sdk=exclude-sdk
      --exclude-pkgs=exclude-pkgs
      --include-private=include-private

  built-toitdoc := builder.build

  file.write-content --path=output (json.encode built-toitdoc)
