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

import system

import cli
import host.directory
import host.file
import encoding.yaml

import ..pkg
import ..project
import ..project.specification
import ..registry
import ..registry.description
import ..license
import ..git
import ..file-system-view

import .base_
import .list


NOT-SCRAPED-STRING ::= "<Not scraped for local paths>"
NOT-SCRAPED-VERSION-STRING ::= "v0.0.0"  // We need a valid version.

class DescribeCommand extends PkgCommand:
  url-path/string?
  version/string?
  out-dir/string?
  allow-local-deps/bool

  constructor invocation/cli.Invocation:
    url-path = invocation[URL-PATH-OPTION]
    version = invocation[VERSION-OPTION]
    out-dir = invocation[OUT-DIR-OPTION]
    allow-local-deps = invocation[ALLOW-LOCAL-DEPS]
    super invocation

  execute:
    if not version:
      execute-local
    else:
      execute-remote

  build-description -> Description
      [--check-src-dir]
      [--load-specification]
      [--load-license-file]
      --hash/string
      --version/string
      --url/string :
    // check for src directory
    if not check-src-dir.call:
      error "No 'src' directory in package."

    specification := load-specification.call
    if not specification:
      error "Missing package.yaml file."

    if not specification.has-name:
      warning "Automatic name extraction from README has been removed."
      error "Missing name"

    if not specification.has-description:
      warning "Automatic description extraction from README has been removed."
      error "Missing description"

    license := specification.license
    if license:
      if not validate-license-id license:
        warning "Unknown SDIX license-ID: '$license'"
    else:
      license-content/ByteArray? := load-license-file.call
      if not license-content:
        error "Missing LICENSE file."

      license-str := license-content.to-string-non-throwing
      if license-str.trim == "":
        error "Empty LICENSE file."

      license = guess-license license-str
      if not license:
        error "Unknown license in 'LICENSE' file"
      ui.emit --verbose "Using license '$license' from 'LICENSE' file."

    if not allow-local-deps and not specification.local-dependencies.is-empty:
      warning "Package has local dependencies."

    description := {
      Description.DESCRIPTION-KEY_: specification.description,
      Description.NAME-KEY_: specification.name,
      Description.VERSION-KEY_: version,
      Description.URL-KEY_: url,
      Description.HASH-KEY_: hash,
    }

    if license:
      description[Description.LICENSE-KEY_] = license

    if not specification.registry-dependencies.is-empty:
      dependencies := specification.registry-dependencies.values.map: | package-dependency/PackageDependency |
        {
          "url": package-dependency.url,
          "version": package-dependency.constraint.to-string,
        }
      description[Description.DEPENDENCIES-KEY_] = dependencies

    environment := specification.environment
    if environment: description[Description.ENVIRONMENT-KEY_] = environment

    return Description description --path="<local>" --ui=ui


  execute-local:
    path := url-path
    if not path: path = directory.cwd
    if out-dir:
      error "The --out-dir flag requires a URL and version"

    src := "$path/src"
    license-path := "$path/LICENSE"
    spec-path := Specification.file-name path
    description := build-description
      --check-src-dir=: file.is-directory src
      --load-specification=: file.is-file spec-path ? ExternalSpecification --dir=path --ui=ui : null
      --load-license-file=: file.is-file license-path ? file.read-contents license-path : null
      --hash=NOT-SCRAPED-STRING
      --version=NOT-SCRAPED-VERSION-STRING
      --url=NOT-SCRAPED-STRING

    output --local description

  execute-remote:
    url := url-path
    if url.starts-with "https://": url = url[8..]
    git := Repository url
    ref-hash := git.refs.get "refs/tags/v$version"
    if not ref-hash:
      error "Tag v$version not found for version '$version'"

    pack := git.clone ref-hash
    file-view/FileSystemView := pack.content
    description := build-description
      --check-src-dir=: (file-view.get "src") is FileSystemView
      --load-specification=:
        package-content := file-view.get Specification.FILE-NAME
        package-content and RepositorySpecification package-content --ui=ui
      --load-license-file=: file-view.get "LICENSE"
      --hash=ref-hash
      --version=version
      --url=url

    if not out-dir:
      output --no-local description
    else:
      output-path := "$out-dir/packages/$url/$version"
      directory.mkdir --recursive output-path
      file.write-contents --path="$output-path/desc.yaml" (yaml.encode description)

  output --local/bool description/Description:
    output-map := ListCommand.verbose-description description --allow-extra-fields
    if local:
      name := output-map.keys.first
      output-map[name][Description.VERSION-KEY_] = NOT-SCRAPED-STRING
      output-map[name][Description.URL-KEY_] = NOT-SCRAPED-STRING
      output-map[name][Description.HASH-KEY_] = NOT-SCRAPED-STRING
    ui.emit-map --result output-map

  static CLI-COMMAND ::=
      cli.Command "describe"
          --help="""
              Generates a description of the given package.

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
          --rest=[
              cli.Option URL-PATH-OPTION
                  --help="The URL or path to the package."
                  --required=false,

              cli.Option VERSION-OPTION
                  --help="The version of the package."
                  --required=false,
            ]
          --options=[
              cli.Option OUT-DIR-OPTION
                  --help="The directory to write the description file to."
                  --required=false,

              cli.Flag ALLOW-LOCAL-DEPS
                  --help="Allow local dependencies."
                  --required=false
                  --default=false,
            ]
          --run=:: (DescribeCommand it).execute

  static URL-PATH-OPTION ::= "URL/Path"
  static VERSION-OPTION ::= "version"
  static OUT-DIR-OPTION ::= "out-dir"
  static ALLOW-LOCAL-DEPS ::= "allow-local-deps"
