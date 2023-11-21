import host.file
import encoding.yaml

import ..dependency.local-solver as local-solver
import ..dependency
import ..semantic-version
import ..constraints

import .project
import .package

abstract class Package:
  prefixes/Map := {:}
  name/string? := null

  constructor:

  abstract enrich-map map/Map project-package-file/ProjectPackageFile
  abstract locators_ -> Set
  abstract package-file -> PackageFile
  abstract sdk-version -> Constraint?

  add-to-map packages/Map project-package-file/ProjectPackageFile:
    sub := {:}
    if not prefixes.is-empty: sub["prefixes"] = prefixes
    enrich-map sub project-package-file
    return packages[name] = sub


class RepositoryPackage extends Package:
  dependencies_/Set // of PackageDependency
  resolved-package_/ResolvedPackage
  project_/Project

  constructor .project_ dependency/PackageDependency .resolved-package_:
    dependencies_ = { dependency }

  url -> string:
    return dependencies_.first.url

  version -> SemanticVersion:
    return resolved-package_.version

  ref-hash -> string:
    return resolved-package_.ref-hash

  enrich-map map/Map project-package-file/ProjectPackageFile:
    map["url"] = url
    map["name"] = name
    map["version"] = version.stringify
    map["hash"] = ref-hash

  locators_ -> Set:
    return dependencies_

  add-dependency dependency/PackageDependency:
    dependencies_.add dependency

  package-file -> PackageFile:
    project_.ensure-downloaded url version
    return project_.load-package-package-file url version

  sdk-version -> Constraint?:
    return resolved-package_.sdk-version

class LocalPackage extends Package:
  local-package_/local-solver.LocalPackage

  constructor .local-package_:

  enrich-map map/Map project-package-file/ProjectPackageFile:
    if not local-package_.absolute:
      map["path"] = local-package_.package-file.relative-path-to project-package-file
    else:
      map["path"] = local-package_.location

  locators_ -> Set:
    return { local-package_.location }

  package-file -> PackageFile:
    return local-package_.package-file

  sdk-version -> Constraint?:
    return local-package_.package-file.sdk-version

class LockFile:
  sdk-version/SemanticVersion? := null
  prefixes/Map := {:}
  packages/List := []
  package-file/ProjectPackageFile

  static FILE-NAME ::= "package.lock"

  constructor .package-file:

  to-map -> Map:
    map := {:}
    if sdk-version: map["sdk"] = "^$sdk-version"
    if not prefixes.is-empty:
      map["prefixes"] = prefixes
    if not packages.is-empty:
      packages-map := {:}
      packages.do: | package/Package | package.add-to-map packages-map package-file
      map["packages"] = packages-map
    return map

  save project-root/string:
    content := to-map
    file-name := "$project-root/$FILE-NAME"
    if content.is-empty:
      file.write_content "# Toit Package File." --path=file-name
    else:
      file.write_content --path=file-name
          yaml.encode content


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
  package-file/ProjectPackageFile
  local-result/local-solver.LocalResult

  blocked-name := {}
  name-to-dependecies := {:}
  dependencies-to-name := {:}
  package-map := {:} // PackageKey -> Package

  constructor .package-file/ProjectPackageFile .local-result/local-solver.LocalResult:

  build -> LockFile:
    print "build: $local-result.local-packages"
    lock-file := LockFile package-file
    local-result.local-packages.do: | _ package/local-solver.LocalPackage |
      count := 0
      while true:
        key := PackageKey "package" "$package.location$(count > 0 ? "-$count" : "")"
        if package-map.contains key: continue
        package-map[key] = LocalPackage package
        break

    mutli-version-urls := identify-multi-version-packages
    resolved-to-repository-package := {:}
    local-result.repository-packages.packages.do: | dependency/PackageDependency package/ResolvedPackage |
      print "lockfile.build $dependency"
      count := 0
      while true:
        id := dependency.url

        if mutli-version-urls.contains id:
          id = "$id-$package.version"

        print "id: $id"
        key := PackageKey "package" "$id$(count > 0 ? "-$count" : "")"
        if package-map.contains key: continue
        package-map[key] = RepositoryPackage package-file.project dependency package
        resolved-to-repository-package[package] = package-map[key]
        break

    local-result.repository-packages.packages.do --values: | package/ResolvedPackage |
      package.dependencies.do: | dependecy/PackageDependency depdent-package/ResolvedPackage |
        resolved-to-repository-package[depdent-package].add-dependency dependecy

    package-map.keys.do: | k/PackageKey | print "key: $k.parts"
    reduced-key-to-key := reduce-keys package-map.keys
    reduced-key-to-key.keys.do: | k/PackageKey | print "reduced key: $k.parts"

    // Update package-map with the shortened keys
    reduced-key-to-key.do: | short/PackageKey long/PackageKey |
      value/Package := package-map[long]
      value.name = short.name
      print "$value.name - $short.parts"
      package-map.remove long
      package-map[short] = value
    package-map.keys.do: | k/PackageKey | print "reduced2: $k.parts"

    // Build a lookup table from PackageDependency/Path to Package
    package-locator-to-package/Map := {:}
    package-map.do: | key/PackageKey package/Package |
      package.locators_.do:
        print "locator: $it"
        package-locator-to-package[it] = package

    print package-locator-to-package.keys

    lock-file.prefixes = compute-prefixes package-file package-locator-to-package

    package-map.do --values: | package/Package |
      package.prefixes = compute-prefixes package.package-file package-locator-to-package

    lock-file.packages = package-map.values.sort: |a b| a.name.compare-to b.name

    lock-file.sdk-version = find-min-sdk-version package-map.values

    return lock-file

  identify-multi-version-packages -> Set:
    mutli-version-urls := {}
    urls := {}
    local-result.repository-packages.packages.do --keys: | dependency/PackageDependency |
      if urls.contains dependency.url: mutli-version-urls.add dependency.url
      urls.add dependency.url
    return mutli-version-urls

  reduce-keys package-keys/List -> Map:
    result := {:}
    input-set := {}
    input-set.add-all package-keys
    prefix-count := 1
    max-size := package-keys.reduce --initial=0: | m key/PackageKey | max m key.parts.size
    print max-size
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
      prefixes[prefix] = package-locator-to-package[package-file.real-path-for-dependecy path].name

    package-file.registry-dependencies.do: | prefix/string dependency/PackageDependency |
      print dependency
      prefixes[prefix] = package-locator-to-package[dependency].name

    return prefixes

  find-min-sdk-version packages/List -> SemanticVersion?:
    min-sdk-version/SemanticVersion? := null

    packages.do: | package/Package |
      sdk-version := package.sdk-version
      if sdk-version:
        if not sdk-version.source.starts-with "^":
          throw "Unexpected sdk-version constraint: $sdk-version"

        version := SemanticVersion sdk-version.source[1..]

        if not min-sdk-version:
          min-sdk-version = version
          continue.do

        if version < min-sdk-version:
          min-sdk-version = version

    return min-sdk-version