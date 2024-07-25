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

import .package
import .lock

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

  package-file-exists -> bool:
    return file.is_file (PackageFile.file-name root)

  lock-file-exists -> bool:
    return file.is_file (LockFile.file-name root)

  verify:
    if not project-root_ and not package-file-exists:
      error
          """
          Command must be executed in project root.
          Run 'toit.pkg init' first to create a new application here, or
            run with '--$OPTION-PROJECT-ROOT=.'
          """

class Project:
  config/ProjectConfiguration
  package-file/ProjectPackageFile? := null
  lock-file/LockFile? := null

  static PACKAGES-CACHE ::= ".packages"

  constructor .config/ProjectConfiguration --empty-lock-file/bool=false:
    if config.package-file-exists:
      package-file = ProjectPackageFile.load this
    else:
      package-file = ProjectPackageFile.empty this

    if config.lock-file-exists:
      lock-file = LockFile.load package-file
    else if empty-lock-file:
      lock-file = LockFile package-file

  root -> string:
    return config.root

  sdk-version -> SemanticVersion:
    return config.sdk-version

  save:
    package-file.save
    lock-file.save

  install-remote prefix/string remote/Description:
    package-file.add-remote-dependency --prefix=prefix --url=remote.url --constraint="^$remote.version"
    solve_
    save

  install-local prefix/string path/string:
    package-file.add-local-dependency prefix path
    solve_
    save

  uninstall prefix/string:
    package-file.remove-dependency prefix
    lock-file.update --remove-prefix=prefix
    save

  update:
    solve_
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

  solve_:
    dependencies := package-file.collect-registry-dependencies
    min-sdk := package-file.compute-min-sdk-version
    solver := Solver registries --sdk-version=sdk-version --outputter=(:: print it)
    solution := solver.solve dependencies --min-sdk-version=min-sdk
    if not solution:
      throw "Unable to resolve dependencies"
    ensure-downloaded_ --solution=solution
    builder := LockFileBuilder --solution=solution --project=this
    lock-file = builder.build

  ensure-downloaded_ --solution/Solution:
    solution.packages.do: | url/string versions/List |
      versions.do: ensure-downloaded url it

  cached-repository-dir_ url/string version/SemanticVersion -> string:
    return "$packages-cache-dir/$url/$version"

  ensure-downloaded url/string version/SemanticVersion:
    cached-repository-dir := cached-repository-dir_ url version
    repo-toit-git-path := "$cached-repository-dir/.toit-git"
    if file.is_file repo-toit-git-path : return
    directory.mkdir --recursive cached-repository-dir
    description := registries.retrieve-description url version
    repository := Repository url
    pack := repository.clone description.ref-hash
    pack.expand cached-repository-dir
    file.write_content description.ref-hash --path=repo-toit-git-path

  load-package-package-file url/string version/SemanticVersion -> ExternalPackageFile:
    cached-repository-dir := cached-repository-dir_ url version
    return ExternalPackageFile --dir=(fs.to-absolute cached-repository-dir)

  load-local-package-file path/string -> ExternalPackageFile:
    return ExternalPackageFile --dir=(fs.to-absolute "$root/$path")

  hash-for --url/string --version/SemanticVersion -> string:
    description := registries.retrieve-description url version
    return description.ref-hash
