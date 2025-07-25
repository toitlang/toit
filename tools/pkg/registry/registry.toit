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

import cli
import cli.cache show Cache FileStore
import fs
import host.file

import .local
import .git
import .description
import ..file-system-view
import ..semantic-version
import ..constraints
import ..utils
import .cache

export LocalRegistry
export GitRegistry

// TODO(florian): move this cache global to a better place. It is used by many other libraries.
cache ::= Cache --app-name="toit_pkg"

/**
A collection of registries.

This class groups all registries and provides a common interface for them.
*/
class Registries:
  registries := {:}
  ui_/cli.Ui

  constructor --ui/cli.Ui:
    ui_ = ui
    encoded-registries := cache.get "registries.yaml": | store/FileStore |
      default-registry := {
        "toit": {
            "url": "github.com/toitware/registry",
            "type": "git"
        }
      }
      store.save (yaml.encode default-registry)

    registries-map := yaml.decode encoded-registries

    registries-map.do: | name/string map/Map |
      type := map.get "type" --if-absent=: ui_.abort "Registry $name does not have a type."
      if type == "git":
        url := map.get "url" --if-absent=: ui_.abort "Registry $name does not have a url."
        ref-hash := map.get "ref-hash"
        ui_.emit --debug "Adding git registry $name $url"
        registries[name] = GitRegistry name url ref-hash --ui=ui_
      else if type == "local":
        path := map.get "path" --if-absent=: ui_.abort "Registry $name does not have a path."
        ui_.emit --debug "Adding local registry $name $path"
        registries[name] = LocalRegistry name path --ui=ui_
      else:
        ui_.abort "Registry $name has an unknown type '$type'"

  constructor.filled .registries/Map --ui/cli.Ui:
    ui_ = ui

  /**
  Searches for the given $search-string in the registry.

  Aborts if no package or multiple packages match the search string.

  Returns the single description with the highest version of the matching package.
  */
  search -> Description
      --registry-name/string?=null
      search-string/string
      [--if-absent]
      [--if-ambiguous]:
    search-results := search_ registry-name search-string
    if search-results.size == 1:
      return search-results[0][1]

    if search-results.is-empty: return if-absent.call
    if not registry-name:
      // Test for the same package appearing in multiple registries.
      urls := {}
      search-results.do:
        urls.add it[1].url
      if urls.size == 1:
        return search-results[0][1]

    // If there is a full match, return that.
    search-results.do:
      if it[1].url == search-string:
        return it[1]

    return if-ambiguous.call

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
      registry/Registry := registries.get registry-name
          --if-absent=: ui_.abort "Registry $registry-name not found."
      search-results := registry.search search-string
      return search-results.map: [registry-name, it]

  retrieve-description url/string version/SemanticVersion -> Description:
    registries.do --values:
      if description := it.retrieve-description url version: return description
    ui_.abort "Not able to find package $url with version $version."
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

  add --local/True name/string path/string:
    if not file.is-directory path: ui_.abort "Path $path is not a directory."
    abs-path := fs.to-absolute path
    add_ name (LocalRegistry name abs-path --ui=ui_)

  add --git/True name/string url/string:
    add_ name (GitRegistry name url null --ui=ui_)

  add_ name/string registry/Registry:
    if registries.contains name:
      old-registry := registries[name]
      if old-registry == registry: return
      ui_.abort "Registry $name already exists."
    registries[name] = registry
    registry.sync  // To check that the url is valid.
    registry.description-cache  // To report broken descriptions.
    registries[name] = registry
    save_

  remove name/string:
    if not registries.contains name: ui_.abort "Registry $name does not exist."
    registries.remove name
    save_

  list:
    data := []
    registries.do: | name registry |
      row := {
        "name": name,
        "type": registry.type,
        "path": registry is GitRegistry ? registry.url : registry.path
      }
      data.add row
    ui_.emit-table --result --header={"name": "Name", "type": "Type", "path": "Url/Path"} data

  list-packages -> Map:
    return registries.map: | name registry/Registry |
      { "registry" : registry, "descriptions": registry.list-all-descriptions }

  sync:
    registries.do --values: it.sync
    save_

  sync --name/string:
    registry := registries.get name --if-absent=: ui_.abort "Registry $name does not exist"
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
  ui_/cli.Ui

  constructor .name --ui/cli.Ui:
    ui_ = ui

  constructor.filled .name descriptions/List --ui/cli.Ui:
    ui_ = ui
    description-cache_ = DescriptionUrlCache.filled descriptions

  abstract type -> string
  abstract content -> FileSystemView
  abstract to-map -> Map
  abstract sync
  abstract to-string -> string

  description-cache -> DescriptionUrlCache:
    if not description-cache_:
      description-cache_ = DescriptionUrlCache content --ui=ui_
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

  /**
  Searches for the given $search-string in the registry.

  A description matches if the name is the same, or if the url ends with
    the search string.

  Returns a list of pairs, where each pair is a list containing the
    registry name and the description with the highest version.
  */
  search search-string/string -> List:
    // Initially maps urls to list of descriptions.
    search-result := description-cache.search search-string

    // Remove empty.
    search-result = search-result.filter: | _ descriptions/List | not descriptions.is-empty

    // Reduce versions.
    search-result = search-result.map: | _ descriptions/List |
      highest-version_ descriptions

    // Now maps from url to one description.
    return search-result.values

  /**
  Searches for the given $search-string in the registry.

  Returns a list of descriptions that match the search string.

  A description matches if the $search-string is a substring of the
    name, description or url. The search is case-insensitive.
  */
  search --free-text/True search-string/string -> List:
    search-string = search-string.to-ascii-lower
    return list-all-descriptions.filter: | description/Description |
      description.matches-free-text search-string

  static highest-version_ descriptions/List -> Description:
    highest/Description := descriptions[0]
    if descriptions.size == 1: return highest
    descriptions[1..].do: | next/Description |
      if highest.version < next.version: highest = next
    return highest

