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
import ..error
import ..project.package
import ..project
import ..registry
import ..registry.description
import ..license
import ..git
import ..file-system-view

import .list


NOT-SCRAPED-STRING ::= "<Not scraped for local paths>"

class DescribeCommand:
  url-path/string? := ?
  version/string?
  out-dir/string?
  allow-local-deps/bool

  constructor parsed/cli.Parsed:
    url-path = parsed[URL-PATH-OPTION]
    version = parsed[VERSION-OPTION]
    out-dir = parsed[OUT-DIR-OPTION]
    allow-local-deps = parsed[ALLOW-LOCAL_DEPS]

  execute:
    if not version:
      execute-local
    else:
      execute-remote

  build-description -> Description
      [--check-src-dir]
      [--load-package-file]
      [--load-license-file]
      --hash/string
      --version/string
      --url/string :
    // check for src directory
    if not check-src-dir.call:
      error "No 'src' directory in package."

    package-file := load-package-file.call
    if not package-file:
      error "Missing package.yaml file."

    if not package-file.description:
      warning "Automatic name/description extraction from README has been removed."
      error "Missing description"

    license := package-file.license
    if license:
      if not validate-license-id license:
        warning "Unknown SDIX license-ID: '$license'"
    else:
      license-content := load-license-file.call
      if not license-content:
        warning "Missing LICENSE file."
      else:
        license = guess-license license-content.to-string
        if not license:
          warning "Unknown license in 'LICENSE' file"

    if not allow-local-deps and not package-file.local-dependencies.is-empty:
      warning "Package has local dependencies."

    description := {
      Description.DESCRIPTION-KEY_: package-file.description,
      Description.NAME-KEY_: package-file.name,
      Description.VERSION-KEY_: version,
      Description.URL-KEY_: url-path,
      Description.HASH-KEY_: hash
    }

    if license: description[Description.LICENSE-KEY_] = license

    if not package-file.registry-dependencies.is-empty:
      dependencies := package-file.registry-dependencies.values.map: | pacakage-dependency/PackageDependency |
        { "url": pacakage-dependency.url, "version": pacakage-dependency.constraint-string }
      description[Description.DEPENDENCIES-KEY_] = dependencies

    environment := package-file.environment
    if environment: description[Description.ENVIRONMENT-KEY_] = environment

    return Description description


  execute-local:
    if not url-path: url-path = directory.cwd
    if out-dir:
      error "The --out-dir flag requires a URL and version"

    src := "$url-path/src"
    description := build-description
      --check-src-dir=: file.is_directory src
      --load-package-file=: file.is_file (PackageFile.file-name url-path) and  ExternalPackageFile url-path
      --load-license-file=: file.is_file "LICENSE" and file.read_content "LICENSE"
      --hash=NOT-SCRAPED-STRING
      --version=NOT-SCRAPED-STRING
      --url=NOT-SCRAPED-STRING

    output description

  execute-remote:
    if url-path.starts-with "https://": url-path = url-path[8..]
    git := Repository url-path
    ref-hash := git.refs.get "refs/tags/v$version"
    if not ref-hash:
      error "Tag v$version not found for version '$version'"

    pack := git.clone ref-hash
    file-view/FileSystemView := pack.content
    description := build-description
      --check-src-dir=: (file-view.get "src") is FileSystemView
      --load-package-file=:
        package-content := file-view.get PackageFile.FILE_NAME
        package-content and RepositoryPackageFile package-content
      --load-license-file=: file-view.get "LICENSE"
      --hash=ref-hash
      --version=version
      --url=url-path

    if not out-dir:
      output description
    else:
      output-path := "$out-dir/packages/$url-path/$version"
      directory.mkdir --recursive output-path
      file.write-content --path="$output-path/desc.yaml" (yaml.encode description)

  output description/Description:
    output-map := ListCommand.verbose-description description --allow-extra-fields
    print (yaml.stringify output-map)

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

              cli.Flag ALLOW-LOCAL_DEPS
                  --help="Allow local dependencies."
                  --required=false
                  --default=false,
            ]
          --run=:: (DescribeCommand it).execute

  static URL-PATH-OPTION ::= "URL/Path"
  static VERSION-OPTION ::= "version"
  static OUT-DIR-OPTION ::= "out-dir"
  static ALLOW-LOCAL_DEPS ::= "allow-local-deps"
