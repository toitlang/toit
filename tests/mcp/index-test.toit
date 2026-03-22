// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import ...tools.mcp.index show DocIndex
import ...tools.toitdoc.src.builder show
    Class
    ClassStructure
    Doc
    Function
    Global
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

ANY-TYPE ::= Type --is-none=false --is-any=true --is-block=false --reference=null
NONE-TYPE ::= Type --is-none=true --is-any=false --is-block=false --reference=null

/** Creates a toitdoc text section with the given $text. */
make-toitdoc text/string -> Toitdoc:
  return Toitdoc --sections=[
    DocSection --title=null --level=0 --statements=[
      DocParagraph --expressions=[DocText --text=text],
    ],
  ]

/** Creates a parameter entry. */
make-parameter name/string -> Parameter:
  return Parameter
      --name=name
      --is-block=false
      --is-named=false
      --is-required=true
      --type=ANY-TYPE
      --default-value=null

/** Creates a function entry with the given $name and $toitdoc-text. */
make-function name/string toitdoc-text/string -> Function:
  return Function
      --name=name
      --is-private=false
      --is-abstract=false
      --is-synthetic=false
      --exported-from=null
      --parameters=[make-parameter "arg"]
      --return-type=NONE-TYPE
      --shape=(Shape --arity=1 --total-block-count=0 --named-block-count=0 --names=[])
      --toitdoc=(make-toitdoc toitdoc-text)

/** Creates a class entry with the given $name, $toitdoc-text, and $methods. */
make-class name/string toitdoc-text/string --methods/List=[] --kind/string="class" -> Class:
  return Class
      --name=name
      --kind=kind
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

/** Creates a global entry with the given $name. */
make-global name/string -> Global:
  return Global
      --name=name
      --is-private=false
      --exported-from=null
      --type=ANY-TYPE
      --toitdoc=null

/** Creates a module entry with the given classes, functions, and globals. */
make-module name/string --classes/List=[] --functions/List=[] --globals/List=[] -> Module:
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
      --globals=globals
      --export-globals=[]
      --toitdoc=null
      --category=null

/** Creates a library with the given $name, $path, sub-$libraries, and $modules. */
make-library name/string --path/List --libraries/Map={:} --modules/Map={:} -> Library:
  return Library
      --name=name
      --path=path
      --libraries=libraries
      --modules=modules
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
Builds fixture 1: single library "core.collections" with a List class
  (with an "add" method) and a "sort" top-level function.
*/
build-fixture-single-library -> Map:
  add-method := make-function "add" "Adds the given value to the list."
  list-class := make-class "List" "A growable list of elements."
      --methods=[add-method]
  sort-function := make-function "sort" "Sorts the given list."

  collections-module := make-module "collections"
      --classes=[list-class]
      --functions=[sort-function]

  return make-doc --libraries={
    "core": make-library "core" --path=["core"]
        --libraries={
          "collections": make-library "collections" --path=["core", "collections"]
              --modules={"collections": collections-module},
        },
  }

/** Builds fixture 2: multiple libraries. Adds "net.http" with a Client class. */
build-fixture-multiple-libraries -> Map:
  fixture := build-fixture-single-library

  client-class := make-class "Client" "An HTTP client."
  http-module := make-module "http" --classes=[client-class]

  libraries := fixture["libraries"] as Map
  libraries["net"] = (make-library "net" --path=["net"]
      --libraries={
        "http": make-library "http" --path=["net", "http"]
            --modules={"http": http-module},
      }).to-json

  return fixture

/** Builds fixture 3: single library with a global variable. */
build-fixture-with-global -> Map:
  fixture := build-fixture-single-library

  // Add the global to the collections module.
  core-lib := (fixture["libraries"] as Map)["core"] as Map
  core-libs := core-lib["libraries"] as Map
  collections-lib := core-libs["collections"] as Map
  modules := collections-lib["modules"] as Map
  collections-module := modules["collections"] as Map
  globals := collections-module["globals"] as List
  globals.add (make-global "EMPTY-LIST").to-json

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
  search-result := index.search --query="List"
  results := search-result["results"] as List

  expect results.size > 0
  first := results[0] as Map
  expect-equals "List" first["name"]
  expect-equals "class" first["kind"]
  expect-equals "core.collections" first["library"]

test-search-function-by-name:
  index := DocIndex (build-fixture-single-library)
  results := (index.search --query="sort")["results"] as List

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
  results := (index.search --query="add")["results"] as List

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
  results := (index.search --query="list")["results"] as List

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

  fixture := make-doc --libraries={
    "core": make-library "core" --path=["core"]
        --libraries={
          "collections": make-library "collections" --path=["core", "collections"]
              --modules={"collections": module},
        },
  }

  index := DocIndex fixture
  // Search with a broad query that matches many elements.
  // Use an empty string or a single common letter to get many results.
  search-result := index.search --query="" --max-results=2
  results := search-result["results"] as List
  expect results.size <= 2
  // Total should reflect all matches, not just the returned results.
  expect (search-result["total"] as int) >= results.size

test-search-no-results:
  index := DocIndex (build-fixture-single-library)
  search-result := index.search --query="nonexistent"
  expect-equals 0 (search-result["results"] as List).size
  expect-equals 0 search-result["total"]

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
