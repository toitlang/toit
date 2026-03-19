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

import expect show *

import ...tools.mcp.store show DocStore

main:
  test-empty-store
  test-add-and-list-scopes
  test-remove
  test-search-all-scopes
  test-search-specific-scope
  test-get-element-all-scopes
  test-get-element-specific-scope
  test-list-libraries-all-scopes
  test-list-libraries-specific-scope
  test-search-max-results-across-scopes

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
make-class name/string toitdoc-text/string --methods/List=[] -> Map:
  return {
    "object_type": "class",
    "name": name,
    "kind": "class",
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

/// Creates a module entry with the given classes and functions.
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

/// Builds fixture A: "sdk" scope with a core.collections library
///   containing a List class with an "add" method.
build-fixture-sdk -> Map:
  add-method := make-function "add" "Adds the given value to the list."
  list-class := make-class "List" "A growable list of elements."
      --methods=[add-method]

  collections-module := make-module "collections"
      --classes=[list-class]

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

/// Builds fixture B: "pkg" scope with an mqtt library
///   containing a Client class with a "connect" method.
build-fixture-pkg -> Map:
  connect-method := make-function "connect" "Connects to the MQTT broker."
  client-class := make-class "Client" "An MQTT client."
      --methods=[connect-method]

  mqtt-module := make-module "mqtt"
      --classes=[client-class]

  return {
    "sdk_version": "v2.0.0",
    "sdk_path": ["path", "to", "sdk"],
    "libraries": {
      "mqtt": {
        "object_type": "library",
        "name": "mqtt",
        "path": ["mqtt"],
        "libraries": {:},
        "modules": {
          "mqtt": mqtt-module,
        },
      },
    },
  }

/// Helper to add both fixtures to a store.
add-both-fixtures store/DocStore:
  store.add --scope="sdk" --json=build-fixture-sdk
  store.add --scope="mqtt" --json=build-fixture-pkg

test-empty-store:
  store := DocStore
  expect-equals 0 store.list-scopes.size
  expect-equals 0 (store.search --query="anything").size
  expect-equals 0 store.list-libraries.size

test-add-and-list-scopes:
  store := DocStore
  add-both-fixtures store

  scopes := store.list-scopes
  expect-equals 2 scopes.size

  found-sdk := false
  found-mqtt := false
  scopes.do:
    if it == "sdk": found-sdk = true
    if it == "mqtt": found-mqtt = true
  expect found-sdk
  expect found-mqtt

test-remove:
  store := DocStore
  add-both-fixtures store

  store.remove --scope="sdk"
  scopes := store.list-scopes
  expect-equals 1 scopes.size
  expect-equals "mqtt" scopes[0]

test-search-all-scopes:
  store := DocStore
  add-both-fixtures store

  list-results := store.search --query="List"
  expect list-results.size > 0
  found-list := false
  list-results.do:
    entry := it as Map
    if entry["name"] == "List": found-list = true
  expect found-list

  client-results := store.search --query="Client"
  expect client-results.size > 0
  found-client := false
  client-results.do:
    entry := it as Map
    if entry["name"] == "Client": found-client = true
  expect found-client

test-search-specific-scope:
  store := DocStore
  add-both-fixtures store

  // Search for "Client" in sdk scope should return empty.
  sdk-results := store.search --query="Client" --scope="sdk"
  found-client := false
  sdk-results.do:
    entry := it as Map
    if entry["name"] == "Client": found-client = true
  expect-not found-client

  // Search for "Client" in mqtt scope should find it.
  mqtt-results := store.search --query="Client" --scope="mqtt"
  expect mqtt-results.size > 0
  found-client = false
  mqtt-results.do:
    entry := it as Map
    if entry["name"] == "Client": found-client = true
  expect found-client

test-get-element-all-scopes:
  store := DocStore
  add-both-fixtures store

  result := store.get-element --library-path="core.collections" --element="List"
  expect-not-null result
  expect-equals "List" result["name"]

test-get-element-specific-scope:
  store := DocStore
  add-both-fixtures store

  // Get Client from mqtt scope should find it.
  mqtt-result := store.get-element --library-path="mqtt" --element="Client" --scope="mqtt"
  expect-not-null mqtt-result
  expect-equals "Client" mqtt-result["name"]

  // Get Client from sdk scope should return null.
  sdk-result := store.get-element --library-path="mqtt" --element="Client" --scope="sdk"
  expect-null sdk-result

test-list-libraries-all-scopes:
  store := DocStore
  add-both-fixtures store

  libs := store.list-libraries
  // Should have libraries from both scopes.
  names := libs.map: (it as Map)["name"]
  found-collections := false
  found-mqtt := false
  names.do:
    if it == "collections": found-collections = true
    if it == "mqtt": found-mqtt = true
  expect found-collections
  expect found-mqtt

test-list-libraries-specific-scope:
  store := DocStore
  add-both-fixtures store

  sdk-libs := store.list-libraries --scope="sdk"
  names := sdk-libs.map: (it as Map)["name"]

  found-collections := false
  found-mqtt := false
  names.do:
    if it == "collections": found-collections = true
    if it == "mqtt": found-mqtt = true
  expect found-collections
  expect-not found-mqtt

test-search-max-results-across-scopes:
  store := DocStore
  add-both-fixtures store

  // Search broadly with max-results=1.
  results := store.search --query="" --max-results=1
  expect results.size <= 1
