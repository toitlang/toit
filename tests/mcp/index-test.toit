// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import ...tools.mcp.index show DocIndex

main:
  test-list-libraries
  test-search-class-by-name
  test-search-function-by-name
  test-search-method-by-name
  test-search-case-insensitive
  test-search-max-results
  test-search-no-results
  test-get-element-class
  test-get-element-function
  test-get-element-not-found
  test-get-element-module

/// Creates a toitdoc text section with the given $text.
make-toitdoc text/string -> List:
  return [
    {
      "object_type": "section",
      "level": 0,
      "statements": [
        {
          "object_type": "statement_paragraph",
          "expressions": [
            {"object_type": "expression_text", "text": text},
          ],
        },
      ],
    },
  ]

/// Creates a parameter entry.
make-parameter name/string -> Map:
  return {
    "object_type": "parameter",
    "name": name,
    "is_block": false,
    "is_named": false,
    "is_required": true,
    "type": {"object_type": "type", "is_none": false, "is_any": true, "is_block": false},
  }

/// Creates a function entry with the given $name and $toitdoc-text.
make-function name/string toitdoc-text/string -> Map:
  return {
    "object_type": "function",
    "name": name,
    "is_private": false,
    "is_abstract": false,
    "is_synthetic": false,
    "parameters": [make-parameter "arg"],
    "return_type": {"object_type": "type", "is_none": true, "is_any": false, "is_block": false},
    "shape": {"object_type": "shape", "arity": 1, "total_block_count": 0, "named_block_count": 0, "names": []},
    "toitdoc": make-toitdoc toitdoc-text,
  }

/// Creates a class entry with the given $name, $toitdoc-text, and $methods.
make-class name/string toitdoc-text/string --methods/List=[] --kind/string="class" -> Map:
  return {
    "object_type": "class",
    "name": name,
    "kind": kind,
    "is_abstract": false,
    "is_private": false,
    "interfaces": [],
    "mixins": [],
    "extends": null,
    "structure": {
      "statics": [],
      "constructors": [],
      "factories": [],
      "fields": [],
      "methods": methods,
    },
    "toitdoc": make-toitdoc toitdoc-text,
  }

/// Creates a global entry with the given $name.
make-global name/string -> Map:
  return {
    "object_type": "global",
    "name": name,
    "is_private": false,
    "type": {"object_type": "type", "is_none": false, "is_any": true, "is_block": false},
  }

/// Creates a module entry with the given classes, functions, and globals.
make-module name/string --classes/List=[] --functions/List=[] --globals/List=[] -> Map:
  return {
    "object_type": "module",
    "name": name,
    "is_private": false,
    "classes": classes,
    "interfaces": [],
    "mixins": [],
    "export_classes": [],
    "export_interfaces": [],
    "export_mixins": [],
    "functions": functions,
    "globals": globals,
    "export_functions": [],
    "export_globals": [],
  }

/// Builds fixture 1: single library "core.collections" with a List class
///   (with an "add" method) and a "sort" top-level function.
build-fixture-single-library -> Map:
  add-method := make-function "add" "Adds the given value to the list."
  list-class := make-class "List" "A growable list of elements."
      --methods=[add-method]
  sort-function := make-function "sort" "Sorts the given list."

  collections-module := make-module "collections"
      --classes=[list-class]
      --functions=[sort-function]

  return {
    "sdk_version": "v2.0.0",
    "sdk_path": ["path", "to", "sdk"],
    "libraries": {
      "core": {
        "object_type": "library",
        "name": "core",
        "path": ["core"],
        "libraries": {
          "collections": {
            "object_type": "library",
            "name": "collections",
            "path": ["core", "collections"],
            "libraries": {:},
            "modules": {
              "collections": collections-module,
            },
          },
        },
        "modules": {:},
      },
    },
  }

/// Builds fixture 2: multiple libraries. Adds "net.http" with a Client class.
build-fixture-multiple-libraries -> Map:
  fixture := build-fixture-single-library

  client-class := make-class "Client" "An HTTP client."
  http-module := make-module "http" --classes=[client-class]

  libraries := fixture["libraries"] as Map
  libraries["net"] = {
    "object_type": "library",
    "name": "net",
    "path": ["net"],
    "libraries": {
      "http": {
        "object_type": "library",
        "name": "http",
        "path": ["net", "http"],
        "libraries": {:},
        "modules": {
          "http": http-module,
        },
      },
    },
    "modules": {:},
  }

  return fixture

/// Builds fixture 3: single library with a global variable.
build-fixture-with-global -> Map:
  fixture := build-fixture-single-library

  // Add the global to the collections module.
  core-lib := (fixture["libraries"] as Map)["core"] as Map
  core-libs := core-lib["libraries"] as Map
  collections-lib := core-libs["collections"] as Map
  modules := collections-lib["modules"] as Map
  collections-module := modules["collections"] as Map
  globals := collections-module["globals"] as List
  globals.add (make-global "EMPTY-LIST")

  return fixture

test-list-libraries:
  index := DocIndex (build-fixture-multiple-libraries)
  libs := index.list-libraries

  expect libs.size >= 2

  names := libs.map: (it as Map)["name"]
  // Check that both libraries are present.
  found-collections := false
  found-http := false
  names.do:
    if it == "collections": found-collections = true
    if it == "http": found-http = true
  expect found-collections
  expect found-http

test-search-class-by-name:
  index := DocIndex (build-fixture-single-library)
  results := index.search --query="List"

  expect results.size > 0
  first := results[0] as Map
  expect-equals "List" first["name"]
  expect-equals "class" first["kind"]
  expect-equals "core.collections" first["library"]

test-search-function-by-name:
  index := DocIndex (build-fixture-single-library)
  results := index.search --query="sort"

  expect results.size > 0
  found := false
  results.do:
    entry := it as Map
    if entry["name"] == "sort":
      expect-equals "function" entry["kind"]
      found = true
  expect found

test-search-method-by-name:
  index := DocIndex (build-fixture-single-library)
  results := index.search --query="add"

  expect results.size > 0
  found := false
  results.do:
    entry := it as Map
    // Members are indexed as "ClassName.member_name".
    if entry["name"] == "List.add":
      expect-equals "method" entry["kind"]
      found = true
  expect found

test-search-case-insensitive:
  index := DocIndex (build-fixture-single-library)
  results := index.search --query="list"

  expect results.size > 0
  found := false
  results.do:
    entry := it as Map
    if entry["name"] == "List":
      found = true
  expect found

test-search-max-results:
  // Build a fixture with many elements to test max-results.
  add-method := make-function "add" "Adds value."
  remove-method := make-function "remove" "Removes value."
  get-method := make-function "get" "Gets value."
  list-class := make-class "List" "A list."
      --methods=[add-method, remove-method, get-method]
  set-class := make-class "Set" "A set."
  map-class := make-class "Map" "A map."
  sort-fn := make-function "sort" "Sorts."
  merge-fn := make-function "merge" "Merges."

  module := make-module "collections"
      --classes=[list-class, set-class, map-class]
      --functions=[sort-fn, merge-fn]

  fixture := {
    "sdk_version": "v2.0.0",
    "sdk_path": ["path", "to", "sdk"],
    "libraries": {
      "core": {
        "object_type": "library",
        "name": "core",
        "path": ["core"],
        "libraries": {
          "collections": {
            "object_type": "library",
            "name": "collections",
            "path": ["core", "collections"],
            "libraries": {:},
            "modules": {
              "collections": module,
            },
          },
        },
        "modules": {:},
      },
    },
  }

  index := DocIndex fixture
  // Search with a broad query that matches many elements.
  // Use an empty string or a single common letter to get many results.
  results := index.search --query="" --max-results=2
  expect results.size <= 2

test-search-no-results:
  index := DocIndex (build-fixture-single-library)
  results := index.search --query="nonexistent"
  expect-equals 0 results.size

test-get-element-class:
  index := DocIndex (build-fixture-single-library)
  result := index.get-element --library-path="core.collections" --element="List"

  expect-not-null result
  expect-equals "List" result["name"]
  expect-equals "class" result["kind"]

  // The class should have members.
  members := result["members"]
  expect-not-null members

test-get-element-function:
  index := DocIndex (build-fixture-single-library)
  result := index.get-element --library-path="core.collections" --element="sort"

  expect-not-null result
  expect-equals "sort" result["name"]

test-get-element-not-found:
  index := DocIndex (build-fixture-single-library)
  result := index.get-element --library-path="core.collections" --element="Nonexistent"

  expect-null result

test-get-element-module:
  index := DocIndex (build-fixture-single-library)
  result := index.get-element --library-path="core.collections"

  expect-not-null result
