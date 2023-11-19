import host.file
import encoding.yaml

import ..dependency.local-solver as local-solver
import ..dependency
import ..semantic-version

import .project
import .package

abstract class Package:
  prefixes/Map := {:}
  name/string? := null

  constructor:

  abstract enrich-map map/Map
  abstract locator_ -> any
  abstract package-file -> PackageFile

  add-to-map packages/Map:
    sub := {:}
    if not prefixes.is-empty: sub["prefixes"] = prefixes
    enrich-map sub
    return packages[name] = sub


class RepositoryPackage extends Package:
  dependency_/PackageDependency
  resolved-package_/ResolvedPackage
  project_/Project

  constructor .project_ .dependency_ .resolved-package_:

  url -> string:
    return dependency_.url

  version -> SemanticVersion:
    return resolved-package_.version

  ref-hash -> string:
    return resolved-package_.ref-hash

  name -> string:
    return resolved-package_.name

  enrich-map map/Map:
    map["url"] = url
    map["name"] = name
    map["version"] = version.stringify
    map["hash"] = ref-hash

  locator_ -> any:
    return dependency_

  package-file -> PackageFile:
    project_.ensure-downloaded url version
    return project_.load-package-package-file url version

class LocalPackage extends Package:
  path/string
  local-package_/local-solver.LocalPackage

  constructor .path .local-package_:

  enrich-map map/Map:
    map["path"] = path

  locator_ -> any:
    return path

  package-file -> PackageFile:
    return local-package_.package-file

class LockFile:
  sdk-version/SemanticVersion? := null
  prefixes/Map := {:}
  packages/List := []

  static FILE-NAME ::= "package.lock"

  constructor:

  to-map -> Map:
    map := {:}
    if sdk-version: map["sdk"] = "^$sdk-version"
    if not prefixes.is-empty:
      map["prefixes"] = prefixes
    if not packages.is-empty:
      packages-map := {:}
      packages.do: it.add-to-map packages-map
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
  package-file/PackageFile
  local-result/local-solver.LocalResult

  blocked-name := {}
  name-to-dependecies := {:}
  dependencies-to-name := {:}
  package-map := {:} // PackageKey -> Package

  constructor .package-file/PackageFile .local-result/local-solver.LocalResult:

  build -> LockFile:
    print "build: $local-result.local-packages"
    lock-file := LockFile
    local-result.local-packages.do: | path/string package/local-solver.LocalPackage |
      print "path=$path"
      count := 0
      while true:
        key := PackageKey "package" "$path$(count > 0 ? "-$count" : "")"
        if package-map.contains key: continue
        package-map[key] = LocalPackage path package
        break

    mutli-version-urls := identify-multi-version-packages
    local-result.repository-packages.packages.do: | dependency/PackageDependency package/ResolvedPackage |
      count := 0
      while true:
        id := dependency.url
        if mutli-version-urls.contains id:
          id = "$id-$package.version"

        key := PackageKey "package" "$id$(count > 0 ? "-$count" : "")"
        if package-map.contains key: continue
        package-map[key] = RepositoryPackage package-file.project dependency package
        break

    reduced-key-to-key := reduce-keys package-map.keys

    // Update package-map with the shortened keys
    reduced-key-to-key.do: | short/PackageKey long/PackageKey |
      value/Package := package-map[long]
      package-map.remove long
      package-map[short] = value
      value.name = short.name

    // Build a lookup table from PackageDependency/Path to Package
    package-locator-to-package/Map := {:}
    package-map.do: | key/PackageKey package/Package |
      package-locator-to-package[package.locator_] = package
    print package-locator-to-package.keys

    lock-file.prefixes = compute-prefixes package-file package-locator-to-package

    package-map.do --values: | package/Package |
      package.prefixes = compute-prefixes package.package-file package-locator-to-package

    lock-file.packages = package-map.values

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
      prefixes[prefix] = package-locator-to-package[path].name

    package-file.registry-dependencies.do: | prefix/string dependency/PackageDependency |
      print dependency
      prefixes[prefix] = package-locator-to-package[dependency].name

    return prefixes