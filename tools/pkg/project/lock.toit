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
  specification -> Specification

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

  ensure-downloaded
  cached-repository-dir -> string


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

  abstract specification -> Specification

  specification url/string version/SemanticVersion -> Specification:
    ensure-downloaded url version
    return project-specification.project.load-package-specification url version

  ensure-downloaded url/string version/SemanticVersion:
    project-specification.project.ensure-downloaded url version

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

  specification -> Specification:
    return specification url version

  ensure-downloaded:
    ensure-downloaded url version

  cached-repository-dir -> string:
    return cached-repository-dir url version

class LoadedLocalPackage extends PackageBase implements LocalPackage:
  path/string

  constructor.from-map name prefixes project-specification/ProjectSpecification map/Map:
    path = map["path"]
    super name prefixes project-specification

  enrich-map map/Map:
    map["path"] = path

  specification -> Specification:
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
    contents/Map := (yaml.decode (file.read_content (file-name specification.root-dir))) or {:}
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
    return "$root/$FILE_NAME"

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

  save:
    content := to-map_
    if content.is-empty:
      file.write_content "# Toit Package File." --path=file-name
    else:
      file.write_content --path=file-name
          yaml.encode content

  install:
    (packages.filter : it is RepositoryPackage).do: | package/RepositoryPackage |
      package.ensure-downloaded

  update --remove-prefix/string:
    name := prefixes[remove-prefix]

    // Build package=to-retain, mapping package name to package
    packages-by-name := {:}
    packages.do: | package/Package | packages-by-name[package.name] = package


    packages-to-remove := {}
    new-packages-to-remove :=  { name }
    // Calculate the transitive closure through prefixes from the name.
    while not new-packages-to-remove.is-empty:
      next := {}
      new-packages-to-remove.do: | name |
        package := packages-by-name[name]
        next.add-all package.prefixes.values
      next.remove-all packages-to-remove
      packages-to-remove.add-all next
      new-packages-to-remove = next

    // Make sure that no retained package has a dependency on the packages-to-remove.
    while true:
      illegal-removed-packages := {}
      packages.do: | package/Package |
        if packages-to-remove.contains package.name: continue.do
        package.prefixes.values.do:
          if packages-to-remove.contains it:
            illegal-removed-packages.add it
      if illegal-removed-packages.is-empty: break
      packages-to-remove.remove-all illegal-removed-packages

    packages.filter --in-place: not packages-to-remove.contains it.name

  repository-packages -> List:
    return (packages.filter : it is RepositoryPackage)


class LockFileBuilder:
  static ALLOWED-PACKAGE-CHARS_ ::= {'.', '-', '_', '/'}

  project_/Project
  solution_/solver.Solution
  url-id-prefixes-map_/Map  // A map from url to ID-prefix.

  constructor --project/Project --solution/solver.Solution:
    project_ = project
    solution_ = solution

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

  build -> LockFile:
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
        hash := project_.hash-for --url=url --version=version
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
          "path": to-uri-path human-path,
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
        throw "Missing version for $dep.url"
      if available-versions.size > 0:
        // We prefer to use higher versions.
        available-versions.sort: | a b | -(a.compare-to b)

      matching := dep.constraint.first-satisfying available-versions
      if not matching:
        throw "No matching version for $dep.url"
      dep-id-prefix := url-id-prefixes-map_[dep.url]
      result[prefix] = "$dep-id-prefix-$matching.major"
    return result
