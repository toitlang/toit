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

  Returns a map with "results" (up to $max-results matches starting at
    $offset, each with a "scope" key) and "total" (total matches across
    all searched scopes).

  If $exact is true, matches element names exactly (case-insensitive).
  If $search-docs is true, also matches against documentation text.
  */
  search --query/string --scope/string?=null --max-results/int
      --offset/int=0 --exact/bool=false --search-docs/bool=false -> Map:
    scoped-indexes := resolve-indexes_ scope
    all-results := []
    total := 0
    scoped-indexes.do: | label/string index/DocIndex |
      search-result := index.search
          --query=query
          --max-results=int.MAX
          --exact=exact
          --search-docs=search-docs
      total += search-result["total"]
      matches := search-result["results"] as List
      matches.do: | entry/Map | entry["scope"] = label
      all-results.add-all matches
    end := min (offset + max-results) all-results.size
    results := offset >= all-results.size ? [] : all-results[offset..end]
    return { "results": results, "total": total }

  /**
  Gets element documentation.

  Searches all scopes or a specific $scope. The $library-path is
    dot-separated, e.g. "core.collections". The $element is the element
    name, optionally dot-separated for members.

  If $include-inherited is true, inherited members are included.

  Returns the first match found, or null.
  */
  get-element --library-path/string --element/string="" --scope/string?=null --include-inherited/bool=false -> Map?:
    scoped-indexes := resolve-indexes_ scope
    scoped-indexes.do: | label/string index/DocIndex |
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
    scoped-indexes := resolve-indexes_ scope
    result := []
    scoped-indexes.do: | label/string index/DocIndex |
      libs := index.list-libraries
      libs.do: | entry/Map | entry["scope"] = label
      result.add-all libs
    return result

  /**
  Returns the indexes to iterate for the given $scope.

  If $scope is null, returns all indexes. If $scope is given, returns a
    single-entry map with that scope's index, or an empty map if not found.
  */
  resolve-indexes_ scope/string? -> Map:
    if not scope: return indexes_
    index := indexes_.get scope
    if not index: return {:}
    return { scope: index }
