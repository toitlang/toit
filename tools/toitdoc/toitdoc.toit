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
import encoding.yaml
import fs
import host.directory
import host.file

import .lsp-exports as lsp
import .serve
import .src.builder show DocsBuilder
import .src.util show kebabify

build-command --sdk-path-from-args/Lambda --toitc-from-args/Lambda -> cli.Command:
  shared-help := """
    If --package is true, then extracts the package name from the
    package.yaml and only includes the 'src' folder. It then also adds
    "To use this library ..." headers to the documentation.

    If --sdk is true, then the documentation for the current SDK is generated.
    No source files are needed in this case.

    The --version option may be used to specify the version of a package or
    application.
    """

  cmd := cli.Command "doc"
      --aliases=["docs", "toitdoc"]
      --help="Generate or serve documentation from Toit source code."
      --options=[
        cli.Flag "package"
            --help="Whether the documentation is for a package.",
        cli.Flag "sdk"
            --help="Whether the documentation is for the SDK.",
        cli.Option "version"
            --help="Version of the package, or application.",
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

  build-command := cli.Command "build"
      --aliases=["generate"]
      --help="""
        Generate a JSON file.

        $shared-help

        The generated file can be served with the toitdocs web-app located
        at https://github.com/toitware/web-toitdocs.
        """
      --options=[
        cli.Option "output"
            --short-name="o"
            --help="Output JSON file."
            --type="file"
            --required,
      ]
      --rest=[
        cli.Option "source"
            --type="file|dir"
            --help="Source directory or file. Defaults to the current directory.",
      ]
      --run=::
        toitdoc-build it
            --toitc=(toitc-from-args.call it)
            --sdk-path=(sdk-path-from-args.call it)
  cmd.add build-command

  serve-command := cli.Command "serve"
      --help="""
          Serve the documentation.

          If the port is 0, a random port is chosen.

          $shared-help
          """
      --options=[
        cli.OptionInt "port"
            --short-name="p"
            --help="Port to serve on."
            --default=0,
      ]
      --rest=[
        cli.Option "source"
            --type="file|dir"
            --help="Source directory or file. Defaults to the current directory.",
      ]
      --run=::
        toitdoc-serve it
            --toitc=(toitc-from-args.call it)
            --sdk-path=(sdk-path-from-args.call it)
  cmd.add serve-command

  return cmd

collect-files root/string -> List:
  pending := Deque
  pending.add root

  result := []
  while not pending.is-empty:
    source := pending.remove-first
    if file.is-directory source:
      stream := directory.DirectoryStream source
      while file-name := stream.next:
        if file-name != ".packages":
          pending.add "$source/$file-name"
    else if file.is-file source and source.ends-with ".toit":
      result.add (fs.to-absolute source)
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

toitdoc invocation/cli.Invocation --toitc/string --sdk-path/string? --output/string -> none:
  for-package := invocation["package"] == true
  for-sdk := invocation["sdk"] == true
  version := invocation["version"]
  exclude-sdk := invocation["exclude-sdk"]
  exclude-pkgs := invocation["exclude-pkgs"]
  include-private := invocation["include-private"]
  source := invocation["source"]

  if for-sdk and exclude-sdk:
    print "Can't exclude the SDK when generating the SDK documentation."
    exit 1

  if for-sdk and for-package:
    print "The flags --sdk and --package can't be used together."
    exit 1

  if source and for-sdk:
    print "No source files are allowed when generating the SDK documentation."
    exit 1

  sdk-path = compute-sdk-path --sdk-path=sdk-path --toitc=toitc

  if for-sdk:
    source = "$sdk-path/lib"
  else if not source:
    source = directory.cwd

  root-path/string := ?
  if file.is-directory source:
    root-path = source
  else:
    root-path = fs.dirname source
  root-path = fs.to-absolute root-path

  pkg-name/string? := null
  if for-package:
    package-yaml-path := fs.join source "package.yaml"
    if not file.is-file package-yaml-path:
      print "No package.yaml found at $package-yaml-path."
      exit 1
    content := yaml.decode (file.read-content package-yaml-path)
    if content is not Map or not content.contains "name":
      print "No 'name' field found in package.yaml."
      exit 1
    pkg-name = kebabify content["name"]

    // Only include the 'src' folder.
    source = fs.join source "src"

  if not file.is-file toitc:
    print "Toit compiler not found at $toitc."
    exit 1
  if not fs.is-absolute toitc:
    toitc = fs.to-absolute toitc

  sdk-uri := lsp.to-uri sdk-path
  if not sdk-uri.ends-with "/": sdk-uri = "$sdk-uri/"

  paths := collect-files source
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
      --is-sdk-doc=for-sdk

  built-toitdoc := builder.build

  if not exclude-pkgs: built-toitdoc["contains_pkgs"] = true
  if not exclude-sdk: built-toitdoc["contains_sdk"] = true
  if for-package: built-toitdoc["mode"] = "package"
  if for-sdk: built-toitdoc["mode"] = "sdk"

  file.write-content --path=output (json.encode built-toitdoc)

toitdoc-build invocation/cli.Invocation --toitc/string --sdk-path/string?:
  output := invocation["output"]

  toitdoc invocation --toitc=toitc --sdk-path=sdk-path --output=output

toitdoc-serve invocation/cli.Invocation --toitc/string --sdk-path/string?:
  port := invocation["port"]

  tmp-dir := directory.mkdtemp "/tmp/toitdoc-"
  try:
    output := "$tmp-dir/toitdoc.json"

    toitdoc invocation --toitc=toitc --sdk-path=sdk-path --output=output
    serve output --port=port
  finally:
    directory.rmdir --recursive tmp-dir
