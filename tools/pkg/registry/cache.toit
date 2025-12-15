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

import .description
import ..constraints
import ..file-system-view
import ..semantic-version

/**
A cache of registry descriptions.

This class collects all descriptions in a registry and builds and groups them by url.
*/
class DescriptionUrlCache:
  cache_/Map := {:} // url -> DescriptionVersionCache.

  constructor content/FileSystemView --ui/Ui:
    recurse_ content --path="" --ui=ui

  constructor.filled descriptions/List:
    descriptions.do: | description/Description |
      add_ description

  all-descriptions -> List:
    result := []
    cache_.values.do: | versions/DescriptionVersionCache |
      result.add-all versions.all-descriptions
    return result

  get-description url/string version/SemanticVersion -> Description?:
    version-cache/DescriptionVersionCache? := cache_.get url
    return version-cache and version-cache.get version

  get-versions url/string -> List?:
    version-cache/DescriptionVersionCache? := cache_.get url
    return version-cache and version-cache.all-versions

  get-descriptions url/string -> List?:
    version-cache/DescriptionVersionCache? := cache_.get url
    return version-cache and version-cache.all-descriptions

  /**
  Returns a map, mapping urls to lists of descriptions.
  */
  search needle/string version-constraint/Constraint? -> Map:
    result := {:}
    cache_.do: | url/string version-cache/DescriptionVersionCache |
      is-match := url.ends-with needle or
          version-cache.all-descriptions.any: | description/Description |
            description.name == needle
      if is-match:
        if not version-constraint:
          result[url] = version-cache.all-descriptions
        else:
          result[url] = version-cache.filter version-constraint
    return result

  recurse_ content/FileSystemView --path/string --ui/Ui:
    e := catch:
      content.list.do: | name/string entry |
        if name.starts-with ".":
          // Skip hidden files and directories.
          continue.do
        if entry is FileSystemView:
          recurse_ entry --ui=ui --path="$path/$name"
          continue.do
        if name != Description.DESCRIPTION-FILE-NAME:
          continue.do

        path = "$path/$name"
        description/Description? := null
        decoded/any := null
        e := catch:
          decoded = yaml.decode (content.get entry)
        if e:
          ui.emit --error "Failed to decode $path as YAML."
          ui.emit --warning "Skipping $path."
          continue.do
        if decoded is not Map:
          ui.emit --error "Expected a map in path, got $decoded."
          ui.emit --warning "Skipping $path."
          continue.do

        e = catch:
          description = Description decoded --path=path --ui=ui
        if e:
          // We expect the Description constructor to have reported the error already.
          ui.emit --warning "Skipping $path."
          continue.do

        e = catch:
          add_ description
        if e:
          ui.emit --warning "Failed to add $description.url@$description.content[Description.VERSION-KEY_] to index."
          ui.emit --warning "Skipping $path."
    if e:
      ui.emit --error "Failed to read $path: $e."
      return

  add_ description/Description:
    cache/DescriptionVersionCache := cache_.get description.url --init=(: DescriptionVersionCache)
    cache.add_ description


/**
A cache of registry descriptions for a url.

This class collects all descriptions for the same url and stores them by version.
*/
class DescriptionVersionCache:
  cache_/Map := {:} // version -> description.

  constructor:

  all-descriptions -> List:
    return cache_.values

  get version/SemanticVersion -> Description?:
    return cache_.get version

  /**
  All versions in this cache.

  The returned list is *not* sorted.
  */
  all-versions -> List?:
    return cache_.keys

  filter version-constraint/Constraint -> List:
    result := []
    cache_.do: | version/SemanticVersion description |
      if version-constraint.satisfies version:
        result.add description
    return result

  add_ description/Description:
    cache_[description.version] = description
