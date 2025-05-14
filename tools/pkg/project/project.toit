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
import ..error
import ..pkg
import ..git
import ..semantic-version
import ..solver

import .lock
import .specification

class ProjectConfiguration:
  project-root_/string?
  cwd_/string
  sdk-version/SemanticVersion

  constructor --project-root/string? --cwd/string --.sdk-version --auto-sync/bool:
    project-root_ = project-root
    cwd_ = cwd
    if auto-sync:
      registries.sync

  root -> string:
    return fs.to-absolute (project-root_ ? project-root_ : cwd_)

  specification-file-exists -> bool:
    return file.is-file (Specification.file-name root)

  lock-file-exists -> bool:
    return file.is-file (LockFile.file-name root)

  verify:
    if not project-root_ and not specification-file-exists:
      error
          """
          Command must be executed in project root.
          Run 'toit.pkg init' first to create a new application here, or
            run with '--$OPTION-PROJECT-ROOT=.'
          """

class Project:
  config/ProjectConfiguration
  specification/ProjectSpecification? := null
  lock-file/LockFile? := null

  static PACKAGES-CACHE ::= ".packages"

  constructor .config/ProjectConfiguration --empty-lock-file/bool=false:
    if config.specification-file-exists:
      specification = ProjectSpecification.load this
    else:
      specification = ProjectSpecification.empty this

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

  install-remote prefix/string remote/Description:
    specification.add-remote-dependency --prefix=prefix --url=remote.url --constraint="^$remote.version"
    solve_ --no-update-everything
    save

  install-local prefix/string path/string:
    specification.add-local-dependency prefix path
    solve_ --no-update-everything
    save

  uninstall prefix/string:
    specification.remove-dependency prefix
    lock-file.update --remove-prefix=prefix
    save

  update:
    solve_ --update-everything
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
  solve_ --update-everything/bool:
    dependencies := specification.collect-registry-dependencies
    min-sdk := specification.compute-min-sdk-version
    solver := Solver registries --sdk-version=sdk-version --outputter=(:: print it)
    if not update-everything and lock-file:
      lock-file.packages.do: | package/Package |
        if package is RepositoryPackage:
          repository-package := package as RepositoryPackage
          solver.set-preferred repository-package.url repository-package.version
    solution := solver.solve dependencies --min-sdk-version=min-sdk
    if not solution:
      throw "Unable to resolve dependencies"
    ensure-downloaded_ --solution=solution
    builder := LockFileBuilder --solution=solution --project=this
    lock-file = builder.build

  ensure-downloaded_ --solution/Solution:
    cached-contents := cached-repository-contents_
    solution.packages.do: | url/string versions/List |
      versions.do:
        cached-contents = ensure-downloaded url it --cached-contents=cached-contents

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

  ensure-downloaded url/string version/SemanticVersion --cached-contents/Map?=null -> Map:
    if not cached-contents: cached-contents = cached-repository-contents_
    version-string := version.to-string
    if cached-contents.contains url and cached-contents[url].contains version-string:
      return cached-contents
    cached-repository-dir := cached-repository-dir_ url version
    relative-dir := relative-cached-repository-dir url version
    assert: cached-repository-dir.ends-with relative-dir
    repo-toit-git-path := "$cached-repository-dir/.toit-git"
    if not file.is-file repo-toit-git-path:
      hash := download_ url version --destination=cached-repository-dir
      file.write-contents hash --path=repo-toit-git-path
    (cached-contents.get url --init=:{:})[version-string] = relative-dir
    write-cached-repository-contents_ cached-contents
    return cached-contents

  download_ url/string version/SemanticVersion --destination/string -> string:
    directory.mkdir --recursive destination
    description := registries.retrieve-description url version
    repository := Repository url
    hash := description.ref-hash
    if not hash:
      // Use the version instead.
      version-tag := "refs/tags/v$version"
      hash = repository.refs.get "refs/tags/v$version"
      if not hash:
        throw "Tag v$version not found for package '$url'"
    pack := repository.clone hash
    pack.expand destination
    return hash

  load-package-specification url/string version/SemanticVersion -> ExternalSpecification:
    cached-repository-dir := cached-repository-dir_ url version
    return ExternalSpecification --dir=(fs.to-absolute cached-repository-dir)

  load-local-specification path/string -> ExternalSpecification:
    return ExternalSpecification --dir=(fs.to-absolute "$root/$path")

  hash-for --url/string --version/SemanticVersion -> string?:
    description := registries.retrieve-description url version
    result := description.ref-hash
    if not result:
      // Use the entry we wrote into the cache-directory.
      toit-git-path := "$(cached-repository-dir_ url version)/.toit-git"
      if not file.is-file toit-git-path:
        throw "No hash found for package '$url' version '$version'"
      result = (file.read-contents toit-git-path).to-string
    return result
