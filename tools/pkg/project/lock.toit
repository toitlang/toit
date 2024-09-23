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
import encoding.yaml

import ..solver.local-solver as local-solver
import ..solver.registry-solver
import ..semantic-version
import ..constraints

import .project
import .package

interface Package:
  prefixes -> Map
  // TODO(florian): we should always have a name. For local packages we would extract it from the folder name.
  name -> string?
  package-file -> PackageFile

  constructor.from-map name/string? map/Map project-package-file/ProjectPackageFile:
    map-prefixes := map.get LockFile.PREFIXES-KEY_ --if-absent=: {:}
    if map.contains LockFile.PATH-KEY_:
      return LoadedLocalPackage.from-map name map-prefixes project-package-file map
    else:
      return LoadedRepositoryPackage.from-map name map-prefixes project-package-file map


interface RepositoryPackage extends Package:
  url -> string
  version -> SemanticVersion
  ref-hash -> string

  ensure-downloaded
  cached-repository-dir -> string


interface LocalPackage extends Package:
  path -> string


abstract class PackageBase implements Package:
  project-package-file/ProjectPackageFile
  prefixes/Map := ?
  name/string? := ?

  constructor .project-package-file:
    prefixes = {:}
    name = null

  constructor .name .prefixes .project-package-file:

  abstract package-file -> PackageFile

  package-file url/string version/SemanticVersion -> PackageFile:
    ensure-downloaded url version
    return project-package-file.project.load-package-package-file url version

  ensure-downloaded url/string version/SemanticVersion:
    project-package-file.project.ensure-downloaded url version

  cached-repository-dir url/string version/SemanticVersion:
    return project-package-file.project.cached-repository-dir_ url version

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

  constructor.from-map name prefixes project-package-file/ProjectPackageFile map/Map:
    url = map["url"]
    version = SemanticVersion.parse map["version"]
    ref-hash = map["hash"]
    super name prefixes project-package-file

  enrich-map map/Map:
    map["url"] = url
    map["version"] = version.stringify
    map["hash"] = ref-hash

  package-file -> PackageFile:
    return package-file url version

  ensure-downloaded:
    ensure-downloaded url version

  cached-repository-dir -> string:
    return cached-repository-dir url version

class LoadedLocalPackage extends PackageBase implements LocalPackage:
  path/string

  constructor.from-map name prefixes project-package-file/ProjectPackageFile map/Map:
    path = map["path"]
    super name prefixes project-package-file

  enrich-map map/Map:
    map["path"] = path

  package-file -> PackageFile:
    return project-package-file.project.load-local-package-file path


abstract class BuiltPackageBase extends PackageBase:
  constructor project-package-file/ProjectPackageFile:
    super project-package-file


  /**
  A locator is either a package dependency or a file path that resolved to this package.
  These locators are used to compute prefixes for packages.
  */
  abstract locators_ -> Set
  abstract sdk-version -> Constraint?


class BuiltRepositoryPackage extends BuiltPackageBase implements RepositoryPackage:
  dependencies_/Set  // of PackageDependency.
  resolved-package_/ResolvedPackage

  constructor project-package-file/ProjectPackageFile dependency/PackageDependency .resolved-package_:
    dependencies_ = { dependency }
    super project-package-file

  url -> string:
    return dependencies_.first.url

  version -> SemanticVersion:
    return resolved-package_.version

  ref-hash -> string:
    return resolved-package_.ref-hash

  enrich-map map/Map:
    map["url"] = url
    map["name"] = name
    map["version"] = version.stringify
    map["hash"] = ref-hash

  locators_ -> Set:
    return dependencies_

  add-dependency dependency/PackageDependency:
    dependencies_.add dependency

  sdk-version -> Constraint?:
    return resolved-package_.sdk-version

  package-file -> PackageFile:
    return package-file url version

  ensure-downloaded:
    ensure-downloaded url version

  cached-repository-dir -> string:
    return cached-repository-dir url version

class BuiltLocalPackage extends BuiltPackageBase implements LocalPackage:
  local-package_/local-solver.LocalPackage

  constructor project-package-file/ProjectPackageFile .local-package_:
    super project-package-file

  enrich-map map/Map:
    map["path"] = path

  path -> string:
    if not local-package_.is-absolute:
      return local-package_.package-file.relative-path-to project-package-file
    else:
      return local-package_.location

  locators_ -> Set:
    return { local-package_.location }

  package-file -> PackageFile:
    return local-package_.package-file

  sdk-version -> Constraint?:
    return local-package_.package-file.sdk-version


class LockFile:
  static SDK-KEY_        ::= "sdk"
  static PREFIXES-KEY_   ::= "prefixes"
  static PACKAGES-KEY_   ::= "packages"
  static PATH-KEY_       ::= "path"

  sdk-version/SemanticVersion? := null
  prefixes/Map := {:}
  packages/List := []
  package-file/ProjectPackageFile

  static FILE-NAME ::= "package.lock"

  constructor .package-file:

  constructor.load .package-file:
    contents/Map := (yaml.decode (file.read_content (file-name package-file.root-dir))) or {:}
    yaml-sdk-version/string? := contents.get SDK-KEY_
    if yaml-sdk-version:
      if not yaml-sdk-version.starts-with "^":
        throw "The sdk version ($yaml-sdk-version) specified in the lock file is not valid. It should start with a ^"
      sdk-version = SemanticVersion.parse contents[SDK-KEY_][1..]

    if contents.contains PREFIXES-KEY_:
      prefixes = contents[PREFIXES-KEY_]

    yaml-packages/Map := contents.get PACKAGES-KEY_ --if-absent=: {:}
    yaml-packages.do: | name/string map/Map |
      packages.add (Package.from-map name map package-file)

  static file-name root/string -> string:
    return "$root/$FILE_NAME"

  file-name -> string:
    return file-name package-file.root-dir

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


class PackageKey:
  parts/List := []

  constructor.private_ .parts:

  constructor prefix/string name/string:
    id := to-valid-package-id "$prefix/$name"
    forward-parts := id.split "/"
    forward-parts.do --reversed: parts.add it

  static ALLOWED-PACKAGE-CHARS ::= {'.', '-', '_', '/'}
  static to-valid-package-id id/string -> string:
    runes := []
    id.size.repeat:
      if rune := id[it]:
        if not it == 0 and '0' <= rune <= '9' or
           'a' <= rune <= 'z' or
           'A' <= rune <= 'Z' or
           ALLOWED-PACKAGE-CHARS.contains rune:
          runes.add rune
        else:
          runes.add '_'
    return string.from-runes runes

  reduce prefix/int -> PackageKey:
    return PackageKey.private_ parts[..(min prefix parts.size)]

  name -> string:
    forward := []
    parts.do --reversed: forward.add it
    return forward.join "/"

  hash-code:
    return parts.reduce --initial=0: | h e | h + e.hash-code

  operator == other:
    if other is not PackageKey: return false
    return other.parts == parts


class LockFileBuilder:
  project-package-file/ProjectPackageFile
  local-result/local-solver.LocalResult

  blocked-name := {}
  name-to-dependecies := {:}
  dependencies-to-name := {:}
  package-map := {:} // PackageKey -> Package.

  constructor .project-package-file .local-result:

  build -> LockFile:
    lock-file := LockFile project-package-file
    local-result.local-packages.do: | _ package/local-solver.LocalPackage |
      count := 0
      while true:
        key := PackageKey "package" "$package.location$(count > 0 ? "-$count" : "")"
        if package-map.contains key:
          count++
          continue
        package-map[key] = BuiltLocalPackage project-package-file package
        break

    multi-version-urls := identify-multi-version-packages
    resolved-to-repository-package := {:}
    local-result.repository-packages.packages.do: | dependency/PackageDependency package/ResolvedPackage |
      count := 0
      while true:
        id := dependency.url

        if multi-version-urls.contains id:
          id = "$id-$package.version"

        key := PackageKey "package" "$id$(count > 0 ? "-$count" : "")"
        if package-map.contains key:
          count++
          continue
        package-map[key] = BuiltRepositoryPackage project-package-file dependency package
        resolved-to-repository-package[package] = package-map[key]
        break

    local-result.repository-packages.packages.do --values: | package/ResolvedPackage |
      package.dependencies.do: | dependecy/PackageDependency depdent-package/ResolvedPackage |
        resolved-to-repository-package[depdent-package].add-dependency dependecy

    reduced-key-to-key := reduce-keys package-map.keys

    // Update package-map with the shortened keys.
    reduced-key-to-key.do: | short/PackageKey long/PackageKey |
      value/PackageBase := package-map[long]
      value.name = short.name
      package-map.remove long
      package-map[short] = value

    // Build a lookup table from PackageDependency/Path to Package.
    package-locator-to-package/Map := {:}
    package-map.do --values: | package/BuiltPackageBase |
      package.locators_.do:
        package-locator-to-package[it] = package

    lock-file.prefixes = compute-prefixes project-package-file package-locator-to-package

    package-map.do --values: | package/PackageBase |
      package.prefixes = compute-prefixes package.package-file package-locator-to-package

    lock-file.packages = package-map.values.sort: |a b| a.name.compare-to b.name

    lock-file.sdk-version = find-min-sdk-version package-map.values

    return lock-file

  identify-multi-version-packages -> Set:
    multi-version-urls := {}
    urls := {}
    local-result.repository-packages.packages.do --keys: | dependency/PackageDependency |
      if urls.contains dependency.url: multi-version-urls.add dependency.url
      urls.add dependency.url
    return multi-version-urls

  reduce-keys package-keys/List -> Map:
    result := {:}
    input-set := {}
    input-set.add-all package-keys
    prefix-count := 1
    max-size := package-keys.reduce --initial=0: | m key/PackageKey | max m key.parts.size
    while not input-set.is-empty and prefix-count <= max-size:
      conflicted := {}
      short-to-long := {:}
      input-set.do: | key/PackageKey |
        reduced := key.reduce prefix-count
        if conflicted.contains reduced: continue.do

        if not short-to-long.contains reduced:
          short-to-long[reduced] = key
        else:
          short-to-long.remove reduced
          conflicted.add reduced

      short-to-long.do: | short/PackageKey long/PackageKey |
        result[short] = long
        input-set.remove long

      prefix-count++

    if not input-set.is-empty:
      throw "Unable to uniquify package identifiers"

    return result

  compute-prefixes package-file/PackageFile package-locator-to-package/Map -> Map:
    prefixes := {:}

    package-file.local-dependencies.do: | prefix/string path/string |
      prefixes[prefix] = package-locator-to-package[package-file.absolute-path-for-dependency path].name

    package-file.registry-dependencies.do: | prefix/string dependency/PackageDependency |
      prefixes[prefix] = package-locator-to-package[dependency].name

    return prefixes

  find-min-sdk-version packages/List -> SemanticVersion?:
    min-sdk-version/SemanticVersion? := null

    packages.do: | package/BuiltPackageBase |
      sdk-version := package.sdk-version
      if sdk-version:
        if not sdk-version.source.starts-with "^":
          throw "Unexpected sdk-version constraint: $sdk-version"

        version := SemanticVersion.parse sdk-version.source[1..]

        if not min-sdk-version:
          min-sdk-version = version
          continue.do

        if version < min-sdk-version:
          min-sdk-version = version

    return min-sdk-version
