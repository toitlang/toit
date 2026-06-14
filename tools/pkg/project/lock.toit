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

import cli show Ui
import encoding.yaml
import fs
import host.file

import ..constraints
import ..registry
import ..solver as solver
import ..semantic-version
import ..utils

import .project
import .specification

interface Package:
  prefixes -> Map
  // TODO(florian): we should always have a name. For local packages we would extract it from the folder name.
  name -> string?
  specification --fs-lock-token/Object -> Specification

  constructor.from-map name/string? map/Map project-specification/ProjectSpecification:
    map-prefixes := map.get LockFile.PREFIXES-KEY_ --if-absent=: {:}
    if map.contains LockFile.PATH-KEY_:
      return LoadedLocalPackage.from-map name map-prefixes project-specification map
    else:
      return LoadedRepositoryPackage.from-map name map-prefixes project-specification map


interface RepositoryPackage extends Package:
  url -> string
  version -> SemanticVersion
  ref-hash -> string

  cached-repository-dir -> string
  is-downloaded -> bool
  ensure-downloaded --fs-lock-token/Object -> none


interface LocalPackage extends Package:
  path -> string


abstract class PackageBase implements Package:
  project-specification/ProjectSpecification
  prefixes/Map := ?
  name/string? := ?

  constructor .project-specification:
    prefixes = {:}
    name = null

  constructor .name .prefixes .project-specification:

  abstract specification --fs-lock-token/Object -> Specification

  cached-repository-dir url/string version/SemanticVersion:
    return project-specification.project.cached-repository-dir_ url version

  abstract enrich-map map/Map

  add-to-map packages/Map:
    sub := {:}
    if not prefixes.is-empty: sub["prefixes"] = prefixes
    enrich-map sub
    return packages[name] = sub


class LoadedRepositoryPackage extends PackageBase implements RepositoryPackage:
  url/string
  version/SemanticVersion
  ref-hash/string

  constructor.from-map name prefixes project-specification/ProjectSpecification map/Map:
    url = map["url"]
    version = SemanticVersion.parse map["version"]
    ref-hash = map["hash"]
    super name prefixes project-specification

  enrich-map map/Map:
    map["url"] = url
    map["version"] = version.stringify
    map["hash"] = ref-hash

  specification --fs-lock-token/Object -> Specification:
    ensure-downloaded --fs-lock-token=fs-lock-token
    return project-specification.project.load-package-specification url version

  is-downloaded -> bool:
    return project-specification.project.is-downloaded url version --hash=ref-hash

  ensure-downloaded --fs-lock-token/Object:
    // TODO(floitsch): don't read the contents every time.
    project-specification.project.ensure-downloaded url version
        --hash=ref-hash
        --fs-lock-token=fs-lock-token

  cached-repository-dir -> string:
    return cached-repository-dir url version

class LoadedLocalPackage extends PackageBase implements LocalPackage:
  path/string

  constructor.from-map name prefixes project-specification/ProjectSpecification map/Map:
    path = map["path"]
    super name prefixes project-specification

  enrich-map map/Map:
    map["path"] = path

  specification --fs-lock-token/Object -> Specification:
    return project-specification.project.load-local-specification path


class LockFile:
  static SDK-KEY_        ::= "sdk"
  static PREFIXES-KEY_   ::= "prefixes"
  static PACKAGES-KEY_   ::= "packages"
  static PATH-KEY_       ::= "path"

  sdk-version/SemanticVersion? := null
  prefixes/Map := {:}
  packages/List := []
  specification/ProjectSpecification

  static FILE-NAME ::= "package.lock"

  constructor .specification:


  constructor.load specification/ProjectSpecification:
    contents/Map := (yaml.decode (file.read-contents (file-name specification.root-dir))) or {:}
    return LockFile.from-map contents specification

  constructor.from-map map/Map .specification:
    yaml-sdk-version/string? := map.get SDK-KEY_
    if yaml-sdk-version:
      if not yaml-sdk-version.starts-with "^":
        throw "The sdk version ($yaml-sdk-version) specified in the lock file is not valid. It should start with a ^"
      sdk-version = SemanticVersion.parse map[SDK-KEY_][1..]

    if map.contains PREFIXES-KEY_:
      prefixes = map[PREFIXES-KEY_]

    yaml-packages/Map := map.get PACKAGES-KEY_ --if-absent=: {:}
    yaml-packages.do: | name/string map/Map |
      packages.add (Package.from-map name map specification)

  static file-name root/string -> string:
    return "$root/$FILE-NAME"

  file-name -> string:
    return file-name specification.root-dir

  to-map_ -> Map:
    map := {:}
    if sdk-version: map[LockFile.SDK-KEY_] = "^$sdk-version"
    if not prefixes.is-empty:
      map[LockFile.PREFIXES-KEY_] = prefixes
    if not packages.is-empty:
      packages-map := {:}
      packages.do: | package/PackageBase | package.add-to-map packages-map
      map[LockFile.PACKAGES-KEY_] = packages-map
    return map

  sorted-deep-copy_ o/any -> any:
    if o is Map:
      result := {:}
      sorted-keys := o.keys.sort
      sorted-keys.do: | key/string |
        result[key] = sorted-deep-copy_ o[key]
      return result
    if o is List:
      return o.map: | it | sorted-deep-copy_ it
    return o

  save -> none:
    content := to-map_
    if content.is-empty:
      file.write-contents "# Toit Package File.\n" --path=file-name
      return

    sorted := content.copy
    if sorted.contains LockFile.PREFIXES-KEY_:
      sorted[LockFile.PREFIXES-KEY_] = sorted-deep-copy_ sorted[LockFile.PREFIXES-KEY_]
    if sorted.contains LockFile.PACKAGES-KEY_:
      sorted[LockFile.PACKAGES-KEY_] = sorted-deep-copy_ sorted[LockFile.PACKAGES-KEY_]
    file.write-contents --path=file-name (yaml.encode sorted)

  is-downloaded -> bool:
    repository-packages := packages.filter : it is RepositoryPackage
    return repository-packages.every: | package/RepositoryPackage |
      package.is-downloaded

  install --fs-lock-token/Object:
    (packages.filter : it is RepositoryPackage).do: | package/RepositoryPackage |
      package.ensure-downloaded --fs-lock-token=fs-lock-token

  update --remove-prefix/string:
    name := prefixes[remove-prefix]
    prefixes.remove remove-prefix

    packages-by-name := {:}
    packages.do: | package/Package | packages-by-name[package.name] = package

    retained := {}
    queue := Deque

    prefixes.do --values: | retained-package-name/string |
      retained.add retained-package-name
      queue.add retained-package-name

    while not queue.is-empty:
      retained-package-name := queue.remove-first
      package := packages-by-name[retained-package-name]
      package.prefixes.do --values: | retained-package-name/string |
        if not retained.contains retained-package-name:
          retained.add retained-package-name
          queue.add retained-package-name

    packages.filter --in-place: retained.contains it.name

  repository-packages -> List:
    return (packages.filter : it is RepositoryPackage)


class LockFileBuilder:
  static ALLOWED-PACKAGE-CHARS_ ::= {'.', '-', '_', '/'}

  project_/Project
  solution_/solver.Solution
  url-id-prefixes-map_/Map  // A map from url to ID-prefix.
  ui_/Ui

  constructor --project/Project --solution/solver.Solution --ui/Ui:
    project_ = project
    solution_ = solution
    ui_ = ui

    used := {}
    url-id-prefixes-map_ = solution_.packages.map: | url/string _ |
      candidate := to-valid-package-id_ url
      counter := 2
      id := candidate
      while used.contains id:
        id = "$candidate-$counter"
        counter++
      used.add id
      id

  static to-valid-package-id_ id/string -> string:
    runes := []
    id.size.repeat:
      if rune := id[it]:
        if not it == 0 and '0' <= rune <= '9' or
           'a' <= rune <= 'z' or
           'A' <= rune <= 'Z' or
           ALLOWED-PACKAGE-CHARS_.contains rune:
          runes.add rune
        else:
          runes.add '_'
    return string.from-runes runes

  build --registries/Registries -> LockFile:
    packages := {:}  /// From id to $Package.
    used-ids := {}  // Just to avoid clashes with local packages.

    min-sdk/SemanticVersion? := null
    update-sdk-version := : | sdk-version-constraint/Constraint? |
      if sdk-version-constraint:
        sdk-version := sdk-version-constraint.to-min-version
        if not min-sdk or sdk-version > min-sdk:
          min-sdk = sdk-version

    urls := solution_.packages.keys.sort
    urls.do: | url/string |
      versions := solution_.packages[url].sort
      versions.do: | version/SemanticVersion |
        specification := project_.load-package-specification url version
        update-sdk-version.call specification.sdk-version
        name := specification.name
        hash := project_.hash-for --url=url --version=version --registries=registries
        id-prefix := url-id-prefixes-map_[url]
        // We simply use the url + major version as key.
        id := "$id-prefix-$version.major"
        used-ids.add id

        prefixes := build-prefixes_ specification.registry-dependencies

        packages[id] = {
          "url": url,
          "version": version.to-string,
          "hash": hash,
          "prefixes": prefixes
        }

    prefixes := {:}
    local-ids := {:}  // From absolute path to id.

    compute-local-id := : | path/string |
      local-ids.get path --init=:
        id := (fs.split path).last
        counter := 2
        while used-ids.contains id:
          id = "$id-$counter"
          counter++
        used-ids.add id
        id

    // Add the local packages.
    project_.specification.visit-local-specifications: | human-path/string absolute-path/string specification/Specification? |
      local-prefixes := ?
      if specification:
        update-sdk-version.call specification.sdk-version
        local-prefixes = build-prefixes_ specification.registry-dependencies
        // Local packages are allowed to have local dependencies.
        specification.local-dependencies.do: | prefix/string path/string |
          dep-path := fs.clean (fs.join absolute-path path)
          local-prefixes[prefix] = compute-local-id.call dep-path
      else:
        local-prefixes = {:}

      if human-path == ".":
        // The entry package.
        prefixes = local-prefixes
      else:
        id := compute-local-id.call absolute-path
        packages[id] = {
          "path": to-compiler-path human-path,
          "prefixes": local-prefixes
        }

    result := {:}
    if min-sdk:
      result[LockFile.SDK-KEY_] = "^$min-sdk"
    result[LockFile.PREFIXES-KEY_] = prefixes
    result[LockFile.PACKAGES-KEY_] = packages
    return LockFile.from-map result project_.specification

  build-prefixes_ deps/Map:
    result := {:}
    deps.keys.sort.do: | prefix/string |
      dep/PackageDependency := deps[prefix]
      available-versions := solution_.packages.get dep.url
      if not available-versions:
        ui_.abort """
          Missing version for $dep.url in solution.
          This can happen when the specification and description are out of sync."""

      if available-versions.size > 0:
        // We prefer to use higher versions.
        available-versions.sort: | a b | -(a.compare-to b)

      matching := dep.constraint.first-satisfying available-versions
      if not matching:
        ui_.abort "No matching version for $dep.url"
      dep-id-prefix := url-id-prefixes-map_[dep.url]
      result[prefix] = "$dep-id-prefix-$matching.major"
    return result
