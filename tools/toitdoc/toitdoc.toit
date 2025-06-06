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
import encoding.json
import encoding.yaml
import fs
import host.directory
import host.file

import .lsp-exports as lsp
import .serve
import .src.builder show DocsBuilder
import .src.util show kebabify

build-command --sdk-path-from-args/Lambda --toit-from-args/Lambda -> cli.Command:
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
            --toit=(toit-from-args.call it)
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
        cli.Flag "open-browser"
            --help="Open the browser after starting the server."
            --default=true,
      ]
      --rest=[
        cli.Option "source"
            --type="file|dir"
            --help="Source directory or file. Defaults to the current directory.",
      ]
      --examples=[
        cli.Example "Serve the documentation for the current directory."
            --arguments=".",
        cli.Example """
            Serve the documentation for the package 'foo' located at ../foo.
            Don't include the SDK, but include dependent packages.
            Use 'v1.2.3' as the version.
            """
            --arguments="--exclude-sdk --exclude-pkgs --version=v1.2.3 ../foo",
      ]
      --run=::
        toitdoc-serve it
            --toit=(toit-from-args.call it)
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
warn-if-not-one-project documents/lsp.Documents --ui/Ui -> none:
  project-uris := documents.all-project-uris
  if project-uris.is-empty:
    throw "No project found."

  if project-uris.size > 1:
    paths := project-uris.map: | it | lsp.to-path it
    ui.emit --warning "More than one project found: $(paths.join ", ")."

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

compute-sdk-path --sdk-path/string? --toit/string? --ui/Ui -> string:
  if sdk-path:
    if not file.is-directory sdk-path:
      ui.abort "SDK not found at $sdk-path"
    if not fs.is-absolute sdk-path:
      sdk-path = fs.to-absolute sdk-path
    return sdk-path

  toit = eval-symlinks toit
  bin-dir := fs.dirname toit
  sdk-path = fs.join bin-dir ".."
  lib-dir := fs.join sdk-path "lib" "toit" "lib"
  if file.is-directory lib-dir:
    return sdk-path
  throw "Couldn't determine SDK path"

toitdoc invocation/cli.Invocation --toit/string --sdk-path/string? --output/string -> none:
  for-package := invocation["package"] == true
  for-sdk := invocation["sdk"] == true
  version := invocation["version"]
  exclude-sdk := invocation["exclude-sdk"]
  exclude-pkgs := invocation["exclude-pkgs"]
  include-private := invocation["include-private"]
  source := invocation["source"]

  ui := invocation.cli.ui

  if for-sdk and exclude-sdk:
    ui.abort "Can't exclude the SDK when generating the SDK documentation."

  if for-sdk and for-package:
    ui.abort "The flags --sdk and --package can't be used together."

  if source and for-sdk:
    ui.abort "No source files are allowed when generating the SDK documentation."

  sdk-path = compute-sdk-path --sdk-path=sdk-path --toit=toit --ui=ui

  if for-sdk:
    source = "$sdk-path/lib/toit/lib"
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
      ui.abort "No package.yaml found at $package-yaml-path."
    content := yaml.decode (file.read-contents package-yaml-path)
    if content is Map:
      if content.contains "name":
        pkg-name = kebabify content["name"]
    if not pkg-name:
      // Probably an older package.
      // Try to find the name from the README.
      readme-path := fs.join source "README.md"
      if file.is-file readme-path:
        readme := (file.read-contents readme-path).to-string
        new-line-pos := readme.index-of "\n"
        first-line/string := ?
        if new-line-pos == -1:
          first-line = readme
        else:
          first-line = readme[..new-line-pos]
        if first-line.starts-with "#":
          start := 0
          while start < first-line.size and first-line[start] == '#':
            start++
          title := first-line[start..].trim.to-ascii-lower
          if title != "":
            pkg-name = kebabify title
    if not pkg-name:
      ui.abort "No 'name' field found in package.yaml."

    // Only include the 'src' folder.
    source = fs.join source "src"

  if not file.is-file toit:
    ui.abort "Toit executable not found at $toit."
  if not fs.is-absolute toit:
    toit = fs.to-absolute toit

  sdk-uri := lsp.to-uri sdk-path
  if not sdk-uri.ends-with "/": sdk-uri = "$sdk-uri/"

  paths := collect-files source
  uris := paths.map: lsp.to-uri (fs.to-absolute it)

  documents := lsp.compute-summaries --uris=uris --toit=toit --sdk-path=sdk-path
  warn-if-not-one-project documents --ui=ui
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

  file.write-contents --path=output (json.encode built-toitdoc)

toitdoc-build invocation/cli.Invocation --toit/string --sdk-path/string?:
  output := invocation["output"]

  toitdoc invocation --toit=toit --sdk-path=sdk-path --output=output

toitdoc-serve invocation/cli.Invocation --toit/string --sdk-path/string?:
  port := invocation["port"]
  open-browser := invocation["open-browser"]

  tmp-dir := directory.mkdtemp "/tmp/toitdoc-"
  try:
    output := "$tmp-dir/toitdoc.json"

    toitdoc invocation --toit=toit --sdk-path=sdk-path --output=output
    serve output --port=port --open-browser=open-browser --cli=invocation.cli
  finally:
    directory.rmdir --recursive tmp-dir
