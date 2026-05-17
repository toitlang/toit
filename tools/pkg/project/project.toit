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

import ..constraints
import ..registry
import ..registry.description
import ..pkg
import ..git
import ..semantic-version
import ..solver
import ..utils

import .lock
import .specification

class ProjectConfiguration:
  project-root_/string?
  cwd_/string
  ui_/cli.Ui
  sdk-version/SemanticVersion

  constructor --project-root/string? --cwd/string --.sdk-version --ui/cli.Ui:
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

    if config.lock-file-exists and not config.specification-file-exists:
      ui.abort "Project has a lock-file, but no specification file."

    if config.specification-file-exists:
      specification = ProjectSpecification.load this --ui=ui
    else:
      specification = ProjectSpecification.empty this --ui=ui

    if config.lock-file-exists:
      lock-file = LockFile.load specification
    else if empty-lock-file:
      lock-file = LockFile specification

    if config.lock-file-exists:
      assert: config.specification-file-exists
      // Check that the two files are (mostly) in sync.
      only-in-lock-file := []
      only-in-specification := []
      dependencies := specification.dependencies
      prefixes := lock-file.prefixes
      specification.dependencies.do --keys: | prefix/string |
        if not prefixes.contains prefix:
          only-in-specification.add prefix
      prefixes.do --keys: | prefix/string |
        if not dependencies.contains prefix:
          only-in-lock-file.add prefix

      if not only-in-lock-file.is-empty or not only-in-specification.is-empty:
        if not only-in-lock-file.is-empty:
          ui_.emit --warning "The following prefixes are only in package.lock: $(only-in-lock-file.join ", ")"
        if not only-in-specification.is-empty:
          ui_.emit --warning "The following prefixes are only in package.yaml: $(only-in-specification.join ", ")"
        ui_.abort "The package.yaml file and package.lock file are not in sync."

  root -> string:
    return config.root

  sdk-version -> SemanticVersion:
    return config.sdk-version

  save -> none:
    specification.save
    lock-file.save

  same-major-version_ version/SemanticVersion -> SemanticVersion:
    return SemanticVersion --major=version.major

  /**
  Install the given $remotes packages with the given $prefixes and $constraints.

  Returns a list of the installed versions.
  */
  install-remote --prefixes/List --remotes/List --constraints/List --registries/Registries -> List:
    assert: prefixes.size == remotes.size
    assert: prefixes.size == constraints.size
    remotes.size.repeat: | i/int |
      prefix/string := prefixes[i]
      remote/Description := remotes[i]
      constraint/Constraint? := constraints[i]
      constraint-str := constraint ? constraints[i].to-string : "^$(same-major-version_ remote.version)"
      specification.add-remote-dependency --prefix=prefix --url=remote.url --constraint=constraint-str
    solution := solve-and-download_ --no-update-everything --registries=registries
    specification.update-remote-dependencies solution

    save

    result := []
    remotes.size.repeat: | i/int |
      remote/Description := remotes[i]
      constraint/Constraint? := constraints[i]
      installed-versions/List := solution.packages[remote.url]
      if installed-versions.size == 1:
        result.add installed-versions[0]
      else if constraint:
        installed-versions.do: | version/SemanticVersion |
          if constraint.satisfies version:
            result.add version
            continue.repeat
        unreachable
      else:
        // Find the highest version.
        highest := installed-versions.reduce: | version1/SemanticVersion version2/SemanticVersion |
          version1 > version2 ? version1 : version2
        result.add highest
    return result

  install-local prefix/string path/string --registries/Registries -> none:
    specification.add-local-dependency prefix path
    solution := solve-and-download_ --no-update-everything --registries=registries
    specification.update-remote-dependencies solution
    save

  uninstall prefix/string -> none:
    specification.remove-dependency prefix
    lock-file.update --remove-prefix=prefix
    save

  update --registries/Registries -> none:
    solution := solve-and-download_ --update-everything --registries=registries
    specification.update-remote-dependencies solution
    save

  install --recompute/bool --registries/Registries -> none:
    if not recompute and lock-file:
      lock-file.install
      return

    solution := solve-and-download_ --no-update-everything --registries=registries
    specification.update-remote-dependencies solution
    save

  clean -> none:
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

  packages-cache-dir -> string:
    return "$config.root/$PACKAGES-CACHE"

  ensure-packages-cache-dir_ -> none:
    dir := packages-cache-dir
    if file.is-directory dir: return
    if file.stat dir:
      ui_.abort "Expected '$dir' to be a directory, but it is a file."
    directory.mkdir --recursive dir
    readme-path := fs.join dir "README.md"
    file.write-contents --path=readme-path """
    # Package Cache Directory

    This directory contains Toit packages that have been downloaded by
    the Toit package management system.

    Generally, the package manager is able to download these packages again.
    It is thus safe to remove this directory.
    """

  /**
  Solves the dependencies of the project.

  If $update-everything is true, doesn't take the lock-file into account, and
    updates all dependencies. Otherwise, uses the lock-file to avoid unnecessary
    changes.

  Downloads all packages.

  Updates the lock-file with the solution, but does not save it.
  */
  solve-and-download_ --update-everything/bool --registries/Registries -> Solution:
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
    return solution

  ensure-downloaded_ --solution/Solution --registries/Registries -> none:
    cached-contents := cached-repository-contents_
    solution.packages.do: | url/string versions/List |
      versions.do:
        cached-contents = ensure-downloaded url it --cached-contents=cached-contents --registries=registries

  /** The directory within the cache where the given package is cached. */
  relative-cached-repository-dir_ url/string version/SemanticVersion -> string:
    url = url.trim --left "http://"
    url = url.trim --left "https://"
    return escape-path "$url/$version"

  /** The full path of the directory within the cache where the given package is cached. */
  cached-repository-dir_ url/string version/SemanticVersion -> string:
    return "$packages-cache-dir/$(relative-cached-repository-dir_ url version)"

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
    e := catch:
      return ensure-downloaded_ url version
          --cached-contents=cached-contents
          --hash=hash
    ui_.abort "Failed to download package '$url@$version': $e"
    unreachable

  ensure-downloaded_ url/string version/SemanticVersion -> Map
      --cached-contents/Map?
      --hash/string:
    if not cached-contents: cached-contents = cached-repository-contents_
    version-string := version.to-string
    if cached-contents.contains url and
        cached-contents[url].contains version-string and
        file.is-directory "$packages-cache-dir/$cached-contents[url][version-string]":
      return cached-contents
    cached-repository-dir := cached-repository-dir_ url version
    relative-dir := relative-cached-repository-dir_ url version
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
      make-read-only_ --recursive cached-repository-dir
    (cached-contents.get url --init=:{:})[version-string] = relative-dir
    write-cached-repository-contents_ cached-contents
    return cached-contents

  download_ url/string version/SemanticVersion --destination/string --hash/string -> none:
    ui_.emit --verbose "Downloading package $url@$version."
    ensure-packages-cache-dir_
    directory.mkdir --recursive destination
    repository := Repository url
    pack := repository.clone hash
    pack.expand destination

  load-package-specification url/string version/SemanticVersion -> ExternalSpecification:
    cached-repository-dir := cached-repository-dir_ url version
    e := catch:
      return ExternalSpecification --dir=(fs.to-absolute cached-repository-dir) --ui=ui_
    if e:
      ui_.abort "Failed to load package specification for '$url@$version': $e"
    unreachable

  load-local-specification path/string -> ExternalSpecification:
    return ExternalSpecification --dir=(fs.to-absolute "$root/$path") --ui=ui_

  hash-for --url/string --version/SemanticVersion --registries/Registries -> string?:
    description := registries.retrieve-description url version
    return description.ref-hash
