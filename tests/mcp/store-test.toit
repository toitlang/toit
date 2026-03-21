// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import ...tools.mcp.store show DocStore
import ...tools.toitdoc.src.builder show
    Class
    ClassStructure
    Doc
    Function
    Library
    Module
    Parameter
    Shape
    Toitdoc
    DocParagraph
    DocSection
    DocText
    Type

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

ANY-TYPE ::= Type --is-none=false --is-any=true --is-block=false --reference=null
NONE-TYPE ::= Type --is-none=true --is-any=false --is-block=false --reference=null

/** Creates a toitdoc with a single text paragraph. */
make-toitdoc text/string -> Toitdoc:
  return Toitdoc --sections=[
    DocSection --title=null --level=0 --statements=[
      DocParagraph --expressions=[DocText --text=text],
    ],
  ]

/** Creates a function entry with the given $name and $toitdoc-text. */
make-function name/string toitdoc-text/string -> Function:
  return Function
      --name=name
      --is-private=false
      --is-abstract=false
      --is-synthetic=false
      --exported-from=null
      --parameters=[
        Parameter
            --name="arg"
            --is-block=false
            --is-named=false
            --is-required=true
            --type=ANY-TYPE
            --default-value=null,
      ]
      --return-type=NONE-TYPE
      --shape=(Shape --arity=1 --total-block-count=0 --named-block-count=0 --names=[])
      --toitdoc=(make-toitdoc toitdoc-text)

/** Creates a class entry with the given $name, $toitdoc-text, and $methods. */
make-class name/string toitdoc-text/string --methods/List=[] -> Class:
  return Class
      --name=name
      --kind="class"
      --is-abstract=false
      --is-private=false
      --exported-from=null
      --interfaces=[]
      --mixins=[]
      --extends=null
      --structure=(ClassStructure
          --statics=[]
          --constructors=[]
          --factories=[]
          --fields=[]
          --methods=methods)
      --toitdoc=(make-toitdoc toitdoc-text)

/** Creates a module entry with the given classes and functions. */
make-module name/string --classes/List=[] --functions/List=[] -> Module:
  return Module
      --name=name
      --is-private=false
      --classes=classes
      --interfaces=[]
      --mixins=[]
      --export-classes=[]
      --export-interfaces=[]
      --export-mixins=[]
      --functions=functions
      --export-functions=[]
      --globals=[]
      --export-globals=[]
      --toitdoc=null
      --category=null

/** Creates a top-level doc fixture. */
make-doc --libraries/Map -> Map:
  return (Doc
      --sdk-version="v2.0.0"
      --sdk-path=["path", "to", "sdk"]
      --version=null
      --pkg-name=null
      --packages-path=null
      --package-names=null
      --libraries=libraries).to-json

/**
Builds fixture A: "sdk" scope with a core.collections library
  containing a List class with an "add" method.
*/
build-fixture-sdk -> Map:
  add-method := make-function "add" "Adds the given value to the list."
  list-class := make-class "List" "A growable list of elements."
      --methods=[add-method]

  collections-module := make-module "collections"
      --classes=[list-class]

  return make-doc --libraries={
    "core": Library
        --name="core"
        --path=["core"]
        --libraries={
          "collections": Library
              --name="collections"
              --path=["core", "collections"]
              --libraries={:}
              --modules={"collections": collections-module}
              --category=null,
        }
        --modules={:}
        --category=null,
  }

/**
Builds fixture B: "pkg" scope with an mqtt library
  containing a Client class with a "connect" method.
*/
build-fixture-pkg -> Map:
  connect-method := make-function "connect" "Connects to the MQTT broker."
  client-class := make-class "Client" "An MQTT client."
      --methods=[connect-method]

  mqtt-module := make-module "mqtt"
      --classes=[client-class]

  return make-doc --libraries={
    "mqtt": Library
        --name="mqtt"
        --path=["mqtt"]
        --libraries={:}
        --modules={"mqtt": mqtt-module}
        --category=null,
  }

/** Helper to add both fixtures to a store. */
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
