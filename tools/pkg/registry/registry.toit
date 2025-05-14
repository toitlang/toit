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

import cli.cache show Cache FileStore
import host.file

import .local
import .git
import .description
import ..file-system-view
import ..error
import ..semantic-version
import ..constraints
import ..utils
import .cache

registries ::= Registries

// TODO(florian): move this cache global to a better place. It is used by many other libraries.
cache ::= Cache --app-name="toit_pkg"

/**
A collection of registries.

This class groups all registries and provides a common interface for them.
*/
class Registries:
  registries := {:}
  error-reporter/Lambda
  outputter/Lambda

  constructor --.error-reporter/Lambda=(:: error it) --.outputter/Lambda=(:: print it):
    registries-map :=
        yaml.decode
            cache.get "registries.yaml": | store/FileStore |
                store.save
                    yaml.encode {
                        "toit": {
                            "url": "github.com/toitware/registry",
                            "type": "git"
                        }
                      }

    registries-map.do: | name/string map/Map |
      type := map.get "type" --if-absent=: error-reporter.call "Registry $name does not have a type."
      if type == "git":
        url := map.get "url" --if-absent=: error-reporter.call "Registry $name does not have a url."
        ref-hash := map.get "ref-hash"
        registries[name] = GitRegistry name url ref-hash
      else if type == "local":
        path := map.get "path" --if-absent=: error-reporter.call "Registry $name does not have a path."
        registries[name] = LocalRegistry name path
      else:
        error "Registry $name has an unknown type '$type'"

  constructor.filled .registries/Map --.error-reporter/Lambda=(:: error it) --.outputter/Lambda=(:: print it):

  search --registry-name/string?=null search-string/string -> Description:
    search-results := search_ registry-name search-string
    if search-results.size == 1:
      return search-results[0][1]

    if search-results.is-empty:
      registry-info := registry-name != null ? "in registry $registry-name." : "in any registry."
      if search-string.contains "@":
        search-string-split := search-string.split "@"
        search-name-suffix := search-string-split[0]
        search-version-prefix := search-string-split[1]
        package-exists := not (search_ registry-name search-name-suffix).is-empty
        if package-exists:
          error-reporter.call "Package '$search-name-suffix' exists but not with version '$search-version-prefix' $registry-info"
      error-reporter.call "Package '$search-string' not found $registry-info"
    else:
      if not registry-name:
        // Test for the same package appearing in multiple registries.
        urls := {}
        search-results.do:
          urls.add it[1].url
        if urls.size == 1:
          return search-results[0][1]

      registry-info := registry-name != null ? "in registry $registry-name." : "in all registries."
      error-reporter.call "Multiple packages found for '$search-string' $registry-info"

    unreachable

  /**
  Searches for the given $search-string in all registries.

  Returns a list of all descriptions that matches.
  */
  search --free-text search-string/string -> List:
    result := []
    registries.do: | name registry/Registry |
      result.add-all
          registry.search --free-text search-string
    return result

  /**
  Searches for the given $search-string in the given $registry-name.

  If no $registry-name is given, searches in all registries.
  Returns a list of matches, where each entry is itself a list containing the
    registry name and the package.
  */
  search_ registry-name/string? search-string/string -> List:
    if not registry-name:
      search-results := []
      registries.do: | name/string registry/Registry |
        search-results.add-all
            (registry.search search-string).map: [name, it]
      return search-results
    else:
      registry/Registry := registries.get registry-name --if-absent=: error-reporter.call "Registry $registry-name not found."
      search-results := registry.search search-string
      return search-results.map: [registry-name, it]

  retrieve-description url/string version/SemanticVersion -> Description:
    registries.do --values:
      if description := it.retrieve-description url version: return description
    error-reporter.call "Not able to find package $url with version $version."
    unreachable

  /**
  Returns all descriptions for the given url.

  The descriptions are sorted by version in descending order.
  */
  retrieve-descriptions url/string -> List:
    seen-versions := {}
    result := []
    registries.do --values: | registry/Registry |
      descriptions := registry.retrieve-descriptions url
      if descriptions:
        descriptions.do: | description/Description |
          if seen-versions.contains description.version: continue.do
          seen-versions.add description.version
          result.add description

    // Sort.
    result.sort --in-place: | a/Description b/Description |
      -(a.version.compare-to b.version)
    return result

  /**
  Returns the versions in the registry for the given url.
  The versions are sorted in descending order.
  */
  retrieve-versions url/string -> List:
    all-versions := {}
    registries.do --values: | registry/Registry |
      if registry-versions := registry.retrieve-versions url:
        all-versions.add-all registry-versions
    if all-versions.is-empty: return []

    semantic-versions := List.from all-versions
    // Sort.
    semantic-versions.sort --in-place

    // Reverse.
    result := []
    semantic-versions.do --reversed: result.add it

    return result

  add --local name/string path/string:
    if not local: throw "INVALID_ARGUMENT"
    if registries.contains name: error-reporter.call "Registry $name already exists."
    registries[name] = LocalRegistry name path
    save_

  add --git name/string url/string:
    if not git: throw "INVALID_ARGUMENT"
    if registries.contains name: error-reporter.call "Registry $name already exists."
    registries[name] = GitRegistry name url null
    registries[name].sync  // To check that the url is valid.
    save_

  remove name/string:
    if not registries.contains name: error-reporter.call "Registry $name does not exist."
    registries.remove name
    save_

  list:
    outputter.call "$(%-10s "Name") $(%-6s "Type") Url/Path"
    outputter.call "$(%-10s "----") $(%-6s "----") --------"
    registries.do: | name registry |
      outputter.call "$(%-10s name) $(%-6s registry.type) $(registry is GitRegistry ? registry.url : registry.path)"

  list-packages -> Map:
    return registries.map: | name registry/Registry |
      { "registry" : registry, "descriptions": registry.list-all-descriptions }

  sync:
    registries.do --values: it.sync
    save_

  sync --name/string:
    registry := registries.get name --if-absent=: error "Registry $name does not exist"
    registry.sync
    save_

  save_:
    registries-map := {:}
    registries.do: | name registry/Registry |
      registries-map[name] = registry.to-map

    cache-file := cache.get-file-path "registries.yaml" : | store/FileStore | store.save #[]
    file.write-contents --path=cache-file (yaml.encode registries-map)


abstract class Registry:
  name/string
  description-cache_/DescriptionUrlCache? := null

  constructor .name:

  constructor.filled .name descriptions/List:
    description-cache_ = DescriptionUrlCache.filled descriptions

  abstract type -> string
  abstract content -> FileSystemView
  abstract to-map -> Map
  abstract sync
  abstract stringify -> string

  description-cache -> DescriptionUrlCache:
    if not description-cache_:
      description-cache_ = DescriptionUrlCache content
    return description-cache_

  list-all-descriptions -> List:
    return description-cache.all-descriptions

  retrieve-description url/string version/SemanticVersion -> Description?:
    return description-cache.get-description url version

  /**
  Returns all versions for the given $url.
  The result is *not* sorted.
  */
  retrieve-versions url/string -> List?:
    return description-cache.get-versions url

  /**
  Returns all descriptions for the given $url.

  The result is *not* sorted.
  */
  retrieve-descriptions url/string -> List?:
    return description-cache.get-descriptions url

  search search-string/string -> List:
    search-version-constraint/Constraint? := null
    if search-string.contains "@":
      split := search-string.split "@"
      search-string = split[0]
      search-version-str := split[1]
      search-version-constraint = Constraint.parse-range search-version-str

    // Initially maps urls to list of descriptions.
    search-result := description-cache.search search-string search-version-constraint

    // Remove empty.
    search-result = search-result.filter: | _ descriptions/List | not descriptions.is-empty

    // Reduce versions.
    search-result = search-result.map: | _ descriptions/List |
      highest-version_ descriptions

    // Now maps from url to one description.
    return search-result.values

  search --free-text search-string/string -> List:
    search-string = search-string.to-ascii-lower
    return list-all-descriptions.filter: | description/Description |
      description.matches-free-text search-string

  static highest-version_ descriptions/List -> Description:
    highest/Description := descriptions[0]
    if descriptions.size == 1: return highest
    descriptions[1..].do: | next/Description |
      if highest.version < next.version: highest = next
    return highest

