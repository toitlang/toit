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

import host.file
import host.directory
import cli
import cli.cache show Cache
import encoding.json
import encoding.yaml
import system
import fs

import ..registry
import ..registry.description
import ..pkg
import ..git
import ..semantic-version
import ..solver

import .lock
import .specification

class ProjectConfiguration:
  project-root_/string?
  cwd_/string
  ui_/cli.Ui
  sdk-version/SemanticVersion
  auto-sync/bool

  constructor --project-root/string? --cwd/string --.sdk-version --.auto-sync/bool --ui/cli.Ui:
    project-root_ = project-root
    cwd_ = cwd
    ui_ = ui

  root -> string:
    return fs.to-absolute (project-root_ ? project-root_ : cwd_)

  specification-file-exists -> bool:
    return file.is-file (Specification.file-name root)

  lock-file-exists -> bool:
    return file.is-file (LockFile.file-name root)

  verify:
    if not project-root_ and not specification-file-exists:
      ui_.abort """
          Command must be executed in project root.
          Run 'toit pkg init' first to create a new application here, or
            run with '--$OPTION-PROJECT-ROOT=.'
          """

class Project:
  config/ProjectConfiguration
  specification/ProjectSpecification? := null
  lock-file/LockFile? := null
  ui_/cli.Ui

  static PACKAGES-CACHE ::= ".packages"

  constructor .config/ProjectConfiguration
      --empty-lock-file/bool=false
      --ui/cli.Ui:
    ui_ = ui
    if config.specification-file-exists:
      specification = ProjectSpecification.load this --ui=ui
    else:
      specification = ProjectSpecification.empty this --ui=ui

    if config.lock-file-exists:
      lock-file = LockFile.load specification
    else if empty-lock-file:
      lock-file = LockFile specification

  root -> string:
    return config.root

  sdk-version -> SemanticVersion:
    return config.sdk-version

  save:
    specification.save
    lock-file.save

  install-remote prefix/string remote/Description --registries/Registries:
    specification.add-remote-dependency --prefix=prefix --url=remote.url --constraint="^$remote.version"
    solve_ --no-update-everything --registries=registries
    save

  install-local prefix/string path/string --registries/Registries:
    specification.add-local-dependency prefix path
    solve_ --no-update-everything --registries=registries
    save

  uninstall prefix/string:
    specification.remove-dependency prefix
    lock-file.update --remove-prefix=prefix
    save

  update --registries/Registries:
    solve_ --update-everything --registries=registries
    save

  install:
    lock-file.install

  clean:
    repository-packages := lock-file.repository-packages
    url-to-version := {:}
    repository-packages.do: | package/RepositoryPackage |
      url-to-version[package.url] = package.version

    urls := directory.DirectoryStream packages-cache-dir
    while url := urls.next:
      if not url-to-version.contains url:
        directory.rmdir --recursive "$packages-cache-dir/$url"
      else:
        versions := directory.DirectoryStream "$packages-cache-dir/$url"
        while version := versions.next:
          if not url-to-version[url].contains version:
            directory.rmdir --recursive "$packages-cache-dir/$url/$version"
        versions.close
    urls.close

  packages-cache-dir:
    return "$config.root/$PACKAGES-CACHE"

  /**
  Solves the dependencies of the project.

  If $update-everything is true, doesn't take the lock-file into account, and
    updates all dependencies. Otherwise, uses the lock-file to avoid unnecessary
    changes.
  */
  solve_ --update-everything/bool --registries/Registries:
    dependencies := specification.collect-registry-dependencies
    min-sdk := specification.compute-min-sdk-version
    solver := Solver registries --sdk-version=sdk-version --ui=ui_
    if not update-everything and lock-file:
      lock-file.packages.do: | package/Package |
        if package is RepositoryPackage:
          repository-package := package as RepositoryPackage
          solver.set-preferred repository-package.url repository-package.version
    solution := solver.solve dependencies --min-sdk-version=min-sdk
    if not solution:
      ui_.abort "Unable to resolve dependencies"
    ensure-downloaded_ --solution=solution --registries=registries
    builder := LockFileBuilder --solution=solution --project=this --ui=ui_
    lock-file = builder.build --registries=registries

  ensure-downloaded_ --solution/Solution --registries/Registries:
    cached-contents := cached-repository-contents_
    solution.packages.do: | url/string versions/List |
      versions.do:
        cached-contents = ensure-downloaded url it --cached-contents=cached-contents --registries=registries

  relative-cached-repository-dir url/string version/SemanticVersion -> string:
    return "$url/$version"

  cached-repository-dir_ url/string version/SemanticVersion -> string:
    return "$packages-cache-dir/$(relative-cached-repository-dir url version)"

  cached-repository-contents_ -> Map:
    contents-path := "$packages-cache-dir/contents.json"
    if not file.is-file contents-path:
      return {:}
    return json.decode (file.read-contents contents-path)

  write-cached-repository-contents_ contents/Map -> none:
    contents-path := "$packages-cache-dir/contents.json"
    file.write-contents (json.encode contents) --path=contents-path

  ensure-downloaded url/string version/SemanticVersion --cached-contents/Map?=null --registries/Registries -> Map:
    description := registries.retrieve-description url version
    hash := description.ref-hash
    return ensure-downloaded url version
      --cached-contents=cached-contents
      --hash=hash

  ensure-downloaded url/string version/SemanticVersion -> Map
      --cached-contents/Map?=null
      --hash/string:
    if not cached-contents: cached-contents = cached-repository-contents_
    version-string := version.to-string
    if cached-contents.contains url and cached-contents[url].contains version-string:
      return cached-contents
    cached-repository-dir := cached-repository-dir_ url version
    relative-dir := relative-cached-repository-dir url version
    assert: cached-repository-dir.ends-with relative-dir
    repo-toit-git-path := "$cached-repository-dir/.toit-git"
    if not file.is-file repo-toit-git-path:
      // Replace the testing hash with the hash of the version tag.
      if hash == "deadbeef1234567890abcdef1234567890abcdef":
        // Use the version instead.
        version-tag := "refs/tags/v$version"
        repository := Repository url
        version-hash := repository.refs.get "refs/tags/v$version"
        if not version-hash:
          throw "Tag v$version not found for package '$url'"
        hash = version-hash
      download_ url version --destination=cached-repository-dir --hash=hash
      file.write-contents hash --path=repo-toit-git-path
    (cached-contents.get url --init=:{:})[version-string] = relative-dir
    write-cached-repository-contents_ cached-contents
    return cached-contents

  download_ url/string version/SemanticVersion --destination/string --hash/string -> none:
    directory.mkdir --recursive destination
    repository := Repository url
    pack := repository.clone hash
    pack.expand destination

  load-package-specification url/string version/SemanticVersion -> ExternalSpecification:
    cached-repository-dir := cached-repository-dir_ url version
    return ExternalSpecification --dir=(fs.to-absolute cached-repository-dir) --ui=ui_

  load-local-specification path/string -> ExternalSpecification:
    return ExternalSpecification --dir=(fs.to-absolute "$root/$path") --ui=ui_

  hash-for --url/string --version/SemanticVersion --registries/Registries -> string?:
    description := registries.retrieve-description url version
    return description.ref-hash
