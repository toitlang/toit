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
import ..utils

import .project
import .lock

/**
The 'package.yaml' file of the project.

Contrary to an $ExternalSpecification or a $RepositorySpecification, project package files
  are mutable. In addition, they can be solved and saved.
*/
class ProjectSpecification extends Specification:
  project/Project

  constructor.empty .project --ui/cli.Ui:
    super --contents={:} --ui=ui

  constructor.load .project --ui/cli.Ui:
    super --path="$project.root/$Specification.FILE-NAME" --ui=ui

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

  /** Updates the remote dependencies with the ones from the solution. */
  update-remote-dependencies solution/Solution:
    dependencies.do: | prefix/string content/Map |
      if not contents.contains Specification.URL-KEY_:
        // Not a remote dependency.
        continue.do
      url := contents[Specification.URL-KEY_]
      versions := solution.packages[url]
      constraint-str := contents[Specification.VERSION-KEY_]
      constraint/Constraint := Constraint.parse constraint-str
      picked-version/SemanticVersion? := null
      for j := 0; j < versions.size; j++:
        version/SemanticVersion := versions[j]
        if constraint.satisfies version:
          picked-version = version
          break
      assert: picked-version != null
      old-simples := constraint.simple-constraints
      new-simples := []
      old-simples.do: | simple/SimpleConstraint |
        if simple.comparator == ">" or simple.comparator == ">=":
          // Replace with the new version.
          new-simples.add (SimpleConstraint ">=" picked-version)
        else:
          new-simples.add simple
      new-constraint := Constraint --simple-constraints=new-simples --source=""
      contents[Specification.VERSION-KEY_] = new-constraint.to-string

  remove-dependency prefix/string:
    if not dependencies.contains prefix: ui_.abort "No package with prefix $prefix"
    dependencies.remove prefix

  save:
    if contents.is-empty:
      file.write-contents "# Toit Package File." --path=file-name
    else:
      file.write-contents --path=file-name
          yaml.encode contents

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
      if not contents.contains Specification.PATH-KEY_: continue.do
      path := contents[Specification.PATH-KEY_]
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

  constructor --.dir/string --ui/cli.Ui --validate/bool=true:
    if not fs.is-absolute dir: ui.abort "Invalid directory '$dir'."
    super --path="$dir/$Specification.FILE-NAME" --ui=ui --validate=validate

  root-dir -> string:
    return dir


/**
A package file from a published package.
Repository package files are read-only.
*/
class RepositorySpecification extends Specification:
  constructor content/ByteArray --ui/cli.Ui:
    super --bytes=content --ui=ui

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

  contents/Map
  ui_/cli.Ui

  static FILE-NAME ::= "package.yaml"

  constructor --path/string --ui/cli.Ui --validate/bool=true:
    if not fs.is-absolute path: ui.abort "Invalid path '$path'."
    bytes := file.read-contents path
    contents = parse_ bytes --ui=ui
    ui_ = ui
    if validate: validate_

  constructor --bytes/ByteArray --ui/cli.Ui --validate/bool=true:
    ui_ = ui
    contents = parse_ bytes --ui=ui
    if validate: validate_

  constructor --.contents --ui/cli.Ui --validate/bool=true:
    ui_ = ui
    if validate: validate_

  static parse_ bytes/ByteArray --ui/cli.Ui -> Map?:
    decoded := yaml.decode bytes --on-error=: | error/string |
      print "INVALID: $error"
      ui.abort "Invalid specification file content: $error."
    if decoded == null:
      str := bytes.to-string
      if str.trim == "":
        // An empty specification. Treat it like an empty map.
        decoded = {:}
    if decoded is not Map:
      ui.abort "Invalid specification file content: not a map."
    return decoded

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
    return contents.get DEPENDENCIES-KEY_ --init=(: {:})

  has-name -> bool:
    return contents.contains NAME-KEY_ and
        contents[NAME-KEY_] is string and
        contents[NAME-KEY_] != ""

  name -> string:
    return contents.get NAME-KEY_ --if-absent=: ui_.abort "Missing 'name' in $file-name."

  name= name/string:
    contents[NAME-KEY_] = name

  has-description -> bool:
    return contents.contains DESCRIPTION-KEY_ and
        contents[DESCRIPTION-KEY_] is string and
        contents[DESCRIPTION-KEY_] != ""

  description -> string:
    return contents.get DESCRIPTION-KEY_ --if-absent=: ui_.abort "Missing 'description' in $file-name."

  description= description/string:
    contents[DESCRIPTION-KEY_] = description

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
      if contents.contains URL-KEY_:
        url := contents[URL-KEY_]
        constraint := Constraint.parse contents[VERSION-KEY_]
        dependencies[prefix] = PackageDependency url --constraint=constraint
    return dependencies

  /** Returns a map of prefix to strings representing the paths of the local packages */
  local-dependencies -> Map:
    dependencies := {:}
    this.dependencies.do: | prefix/string content/Map |
      if contents.contains PATH-KEY_:
        dependencies[prefix] = contents[PATH-KEY_]
    return dependencies

  license -> string?: return contents.get LICENSE-KEY_
  environment -> Map?: return contents.get ENVIRONMENT-KEY_

  validate_ -> none:
    // Might not be a string.
    name-entry := contents.get NAME-KEY_
    if name-entry and not is-valid-name_ name-entry:
      ui_.abort "Invalid package name '$name-entry'."

    description-entry := contents.get DESCRIPTION-KEY_
    if description-entry and not description-entry is string:
      ui_.abort "Invalid package description '$description-entry'."

    license-entry := contents.get LICENSE-KEY_
    if license-entry and not license-entry is string:
      ui_.abort "Invalid license '$license-entry'."

    environment-entry := contents.get ENVIRONMENT-KEY_
    if environment-entry and environment-entry is not Map:
      ui_.abort "Invalid environment entry: $environment-entry"

    if environment-entry:
      sdk-entry := environment-entry.get SDK-KEY_
      if sdk-entry:
        if sdk-entry is not string:
          ui_.abort "Invalid SDK constraint '$sdk-entry'."
        Constraint.parse sdk-entry --on-error=: | error/string |
          ui_.abort "Invalid SDK constraint '$sdk-entry': $error"

    dependencies-entry := contents.get DEPENDENCIES-KEY_
    if dependencies-entry:
      if dependencies-entry is not Map:
        ui_.abort "Invalid dependencies entry: $dependencies-entry"

      dependencies-entry.do: | prefix/string dependency |
        validate-dependency_ prefix dependency

  validate-dependency_ prefix/string dependency -> none:
    if not is-valid-name_ prefix:
      ui_.abort "Invalid dependency prefix '$prefix'."

    if dependency is not Map:
      ui_.abort "Invalid dependency entry for '$prefix': $dependency"

    dependency-map := dependency as Map

    url := dependency-map.get URL-KEY_
    if url and not url is string or url == "":
      ui_.abort "Invalid URL '$url'."

    path := dependency-map.get PATH-KEY_
    if path and not path is string or path == "":
      ui_.abort "Invalid path '$path'."

    if url and path:
      ui_.abort "Cannot have both URL and path in a package dependency."

    version := dependency-map.get VERSION-KEY_
    if version:
      if not version is string or version == "":
        ui_.abort "Invalid version '$version'."
      Constraint.parse version --on-error=: | error/string |
        ui_.abort "Invalid version '$version': $error"

    if path and version:
      ui_.abort "Cannot have both path and version in a package dependency."

    if url and not version:
      ui_.abort "Remote dependencies must have a version constraint."

  is-valid-name_ name -> bool:
    if not name is string: return false

    return is-valid-toit-identifier name

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


