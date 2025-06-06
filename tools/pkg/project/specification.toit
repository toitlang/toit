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
import host.file
import host.directory
import fs

import encoding.yaml

import ..registry
import ..constraints
import ..semantic-version
import ..solver

import .project
import .lock

/**
The 'package.yaml' file of the project.

Contrary to an $ExternalSpecification or a $RepositorySpecification, project package files
  are mutable. In addition, they can be solved and saved.
*/
class ProjectSpecification extends Specification:
  project/Project

  constructor.private_ .project content/Map --ui/cli.Ui:
    super content --ui=ui

  constructor.empty project/Project --ui/cli.Ui:
    return ProjectSpecification.private_ project {:} --ui=ui

  constructor.load project/Project --ui/cli.Ui:
    file-content := (yaml.decode (file.read-contents "$project.root/$Specification.FILE-NAME")) or {:}
    return ProjectSpecification.private_ project file-content --ui=ui

  root-dir -> string:
    return project.root

  add-remote-dependency --prefix/string --url/string --constraint/string:
    dependencies[prefix] = {
      Specification.URL-KEY_: url,
      Specification.VERSION-KEY_: constraint
    }

  add-local-dependency prefix/string path/string:
    dependencies[prefix] = {
      Specification.PATH-KEY_: path
    }

  remove-dependency prefix/string:
    if not dependencies.contains prefix: ui_.abort "No package with prefix $prefix"
    dependencies.remove prefix

  save:
    if content.is-empty:
      file.write-contents "# Toit Package File." --path=file-name
    else:
      file.write-contents --path=file-name
          yaml.encode content

  /**
  Transitively visits all local packages that are reachable from
    this project package file.

  The given $block is called for each local dependency with three arguments:
  - the path to the package.
  - an absolute path to the package.
  - the $Specification, if one exists.
  The path to the package is how the package was found and depends on how
    the local dependency was declared in the package file. It may be
    relative or absolute.
  The $block is only called once for each local dependency.
  The $block is called with "." as path for this project package file.
  */
  visit-local-specifications [block]:
    entry-dir := fs.dirname (fs.to-absolute file-name)
    already-visited := {}
    relative-paths := {:}
    block.call "." entry-dir this
    already-visited.add entry-dir
    visit-local-dependencies_ this
        --package-path="."
        --already-visited=already-visited
        --entry-dir=entry-dir
        block

  visit-local-dependencies_ specification/Specification
      --package-path/string
      --already-visited/Set
      --entry-dir/string
      [block]:
    specification.dependencies.do: | prefix/string content/Map |
      if not content.contains Specification.PATH-KEY_: continue.do
      path := content[Specification.PATH-KEY_]
      absolute-path/string := fs.clean (specification.absolute-path-for-dependency path)
      if already-visited.contains absolute-path: continue.do
      already-visited.add absolute-path

      // The "human" path is how the package was found relative to the entry package file.
      human-path/string := path
      if fs.is-relative human-path and package-path:
        // Needs to be relative to the entry package file.
        human-path = fs.join package-path human-path

      // At this point, the human-path is either absolute or relative to $this package file.

      if fs.is-relative human-path:
        // Clean the relative path, so we don't have unnecessary '../foo/bar' if we are
        // in a folder 'foo'. It should just be "bar".
        human-path = fs.to-relative --base=entry-dir human-path

      dep-specification-path/string := fs.join absolute-path Specification.FILE-NAME
      // Local packages are allowed not to have a package file.
      if file.is-file dep-specification-path:
        dep-specification := ExternalSpecification --dir=absolute-path --ui=ui_
        block.call human-path absolute-path dep-specification
        // Recursively visit the dependencies of the local package.
        visit-local-dependencies_
            dep-specification
            --package-path=human-path
            --already-visited=already-visited
            --entry-dir=entry-dir
            block
      else:
        block.call human-path absolute-path null

  /**
  Collects all registry dependencies of this project package file.

  This includes dependencies that are transitively added due to local dependencies.
  */
  collect-registry-dependencies -> List:
    result := []
    visit-local-specifications: | _ _ dep-specification/Specification? |
      if dep-specification:
        result.add-all dep-specification.registry-dependencies.values
    return result

  /**
  Computes the minimum SDK version required by this project package file.
  That's the maximum of the SDK versions of this package file and all its dependencies.

  Takes transitive local dependencies into account.
  */
  compute-min-sdk-version -> SemanticVersion?:
    min-sdk := sdk-version and sdk-version.to-min-version
    visit-local-specifications: | _ _ dep-specification/Specification? |
      if dep-specification and dep-specification.sdk-version:
        dep-sdk-version := dep-specification.sdk-version.to-min-version
        if not min-sdk or dep-sdk-version > min-sdk:
          min-sdk = dep-sdk-version
    return min-sdk


/**
An external package file.

External package files are the same as the entry package file, but they are read-only.
*/
class ExternalSpecification extends Specification:
  dir/string

  constructor --.dir --ui/cli.Ui:
    if not fs.is-absolute dir: throw "INVALID_ARGUMENT"
    super ((yaml.decode (file.read-contents "$dir/$Specification.FILE-NAME")) or {:}) --ui=ui

  root-dir -> string:
    return dir


/**
A package file from a published package.
Repository package files are read-only.
*/
class RepositorySpecification extends Specification:
  constructor content/ByteArray --ui/cli.Ui:
    super (yaml.decode content) --ui=ui

  root-dir -> string:
    throw "Not possible to get root dir of a repository package file"

abstract class Specification:
  static DEPENDENCIES-KEY_ ::= "dependencies"
  static NAME-KEY_         ::= "name"
  static URL-KEY_          ::= "url"
  static VERSION-KEY_      ::= "version"
  static PATH-KEY_         ::= "path"
  static ENVIRONMENT-KEY_  ::= "environment"
  static SDK-KEY_          ::= "sdk"
  static DESCRIPTION-KEY_  ::= "description"
  static LICENSE-KEY_      ::= "license"

  content/Map
  ui_/cli.Ui

  static FILE-NAME ::= "package.yaml"

  constructor .content --ui/cli.Ui:
    ui_ = ui

  // The absolute path to the directory holding the package.yaml file.
  abstract root-dir -> string

  static file-name root/string -> string:
    return "$root/$FILE-NAME"

  file-name -> string:
    return file-name root-dir

  relative-path-to project-package/ProjectSpecification -> string:
    my-dir := root-dir
    other-dir := directory.realpath project-package.root-dir
    if other-dir == my-dir: ui_.abort "Reference to self in $project-package.file-name"

    return fs.to-relative my-dir --base=other-dir

  absolute-path-for-dependency path/string:
    if fs.is-absolute path: return path
    if fs.is-rooted path: return fs.to-absolute path
    return fs.to-absolute (fs.join root-dir path)

  dependencies -> Map:
    if not content.contains DEPENDENCIES-KEY_:
      content[DEPENDENCIES-KEY_] = {:}
    return content[DEPENDENCIES-KEY_]

  name -> string:
    return content.get NAME-KEY_ --if-absent=: ui_.abort "Missing 'name' in $file-name."

  name= name/string:
    content[NAME-KEY_] = name

  description -> string:
    return content.get DESCRIPTION-KEY_ --if-absent=: ui_.abort "Missing 'description' in $file-name."

  description= description/string:
    content[DESCRIPTION-KEY_] = description

  sdk-version -> Constraint?:
    if environment_ := environment:
      if environment_.contains SDK-KEY_:
        return Constraint.parse environment_[SDK-KEY_]
    return null

  has-package package-name/string:
    return dependencies.contains package-name

  /** Returns a map from prefix to $PackageDependency objects. */
  registry-dependencies -> Map:
    dependencies := {:}
    this.dependencies.do: | prefix/string content/Map |
      if content.contains URL-KEY_:
        url := content[URL-KEY_]
        constraint := Constraint.parse content[VERSION-KEY_]
        dependencies[prefix] = PackageDependency url --constraint=constraint
    return dependencies

  /** Returns a map of prefix to strings representing the paths of the local packages */
  local-dependencies -> Map:
    dependencies := {:}
    this.dependencies.do: | prefix/string content/Map |
      if content.contains PATH-KEY_:
        dependencies[prefix] = content[PATH-KEY_]
    return dependencies

  license -> string?: return content.get LICENSE-KEY_
  environment -> Map?: return content.get ENVIRONMENT-KEY_


/**
Represents a dependency on a package from a repository.

For convenience it contains delegate methods to contraint.
*/
class PackageDependency:
  url/string
  constraint/Constraint
  hash-code_/int? := null

  constructor .url --.constraint:

  filter versions/List -> List:
    return constraint.filter versions

  satisfies version/SemanticVersion -> bool:
    return constraint.satisfies version

  hash-code -> int:
    if not hash-code_:
      hash-code_ = url.hash-code * 23 + constraint.hash-code
    return hash-code_

  operator == other -> bool:
    if other is not PackageDependency: return false
    return url == other.url and hash-code == other.hash-code and constraint == other.constraint

  stringify: return "$url:$constraint"


