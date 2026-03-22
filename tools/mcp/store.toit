// Copyright (C) 2026 Toit contributors.
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

import .index show DocIndex

/**
Manages multiple $DocIndex instances keyed by scope labels.

Provides unified search and lookup across all loaded documentation
  sources, or within a specific scope.
*/
class DocStore:
  /** Map from scope label to $DocIndex. */
  indexes_ /Map := {:}

  constructor:

  /**
  Adds documentation from parsed toitdoc JSON with the given $scope label.

  If a source with this scope already exists, it is replaced.
  */
  add --scope/string --json/Map -> none:
    indexes_[scope] = DocIndex json

  /**
  Removes a documentation source by $scope label.
  */
  remove --scope/string -> none:
    indexes_.remove scope

  /**
  Returns list of loaded scope labels as strings.
  */
  list-scopes -> List:
    return indexes_.keys

  /**
  Searches across all loaded sources, or only within the given $scope.

  Returns up to $max-results matches. Each match includes a "scope" key
    identifying which source it came from.
  */
  search --query/string --scope/string?=null --max-results/int=10 -> List:
    if scope:
      index := indexes_.get scope
      if not index: return []
      results := index.search --query=query --max-results=max-results
      results.do: | entry/Map | entry["scope"] = scope
      return results

    result := []
    indexes_.do: | label/string index/DocIndex |
      if result.size >= max-results: return result
      remaining := max-results - result.size
      matches := index.search --query=query --max-results=remaining
      matches.do: | entry/Map | entry["scope"] = label
      result.add-all matches
    return result

  /**
  Gets element documentation.

  Searches all scopes or a specific $scope. The $library-path is
    dot-separated, e.g. "core.collections". The $element is the element
    name, optionally dot-separated for members.

  If $include-inherited is true, inherited members are included.

  Returns the first match found, or null.
  */
  get-element --library-path/string --element/string="" --scope/string?=null --include-inherited/bool=false -> Map?:
    if scope:
      index := indexes_.get scope
      if not index: return null
      found := index.get-element
          --library-path=library-path
          --element=element
          --include-inherited=include-inherited
      if found: found["scope"] = scope
      return found

    indexes_.do: | label/string index/DocIndex |
      found := index.get-element
          --library-path=library-path
          --element=element
          --include-inherited=include-inherited
      if found:
        found["scope"] = label
        return found
    return null

  /**
  Lists libraries from all scopes or a specific $scope.

  Each entry includes a "scope" key identifying which source it came from.
  */
  list-libraries --scope/string?=null -> List:
    if scope:
      index := indexes_.get scope
      if not index: return []
      results := index.list-libraries
      results.do: | entry/Map | entry["scope"] = scope
      return results

    result := []
    indexes_.do: | label/string index/DocIndex |
      libs := index.list-libraries
      libs.do: | entry/Map | entry["scope"] = label
      result.add-all libs
    return result
