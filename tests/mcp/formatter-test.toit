// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import ...tools.mcp.formatter show DocFormatter
import ...tools.toitdoc.src.builder show
    DocCodeSection
    DocCode
    DocItem
    DocItemized
    DocLink
    DocParagraph
    DocSection
    DocText
    Toitdoc

main:
  test-format-library-list
  test-format-library-list-empty
  test-format-search-results
  test-format-search-results-empty
  test-format-element-class
  test-format-element-class-overloaded
  test-format-element-function
  test-format-toitdoc-text
  test-format-toitdoc-code
  test-format-toitdoc-link
  test-format-toitdoc-code-section
  test-format-toitdoc-itemized
  test-format-toitdoc-null

/** Creates a toitdoc text section with the given $text. */
make-toitdoc text/string -> Toitdoc:
  return make-toitdoc-expressions [DocText --text=text]

/** Creates a toitdoc section with the given $expressions. */
make-toitdoc-expressions expressions/List -> Toitdoc:
  return make-toitdoc-statements [DocParagraph --expressions=expressions]

/** Creates a toitdoc section with the given $statements. */
make-toitdoc-statements statements/List -> Toitdoc:
  return Toitdoc --sections=[
    DocSection --title=null --level=0 --statements=statements,
  ]

test-format-library-list:
  entries := [
    {"name": "core", "path": ["core"], "sub_libraries": ["collections", "utils"]},
    {"name": "net", "path": ["net"], "sub_libraries": ["http", "tcp"]},
  ]

  output := DocFormatter.format-library-list entries

  expect-equals """
      # Available Libraries

      ## core
      Sub-libraries: collections, utils

      ## net
      Sub-libraries: http, tcp"""
      output

test-format-library-list-empty:
  output := DocFormatter.format-library-list []

  expect-equals """
      # Available Libraries

      No libraries found."""
      output

test-format-search-results:
  results := [
    {"name": "List", "kind": "class", "library": "core.collections", "summary": "A growable list."},
    {"name": "Map", "kind": "class", "library": "core.collections", "summary": "A key-value mapping."},
  ]

  output := DocFormatter.format-search-results {"results": results, "total": 2} --query="collection"

  expect-equals """
      # Search Results for "collection"

      Showing 2 of 2 results.

      1. **List** (class) - core.collections
         A growable list.

      2. **Map** (class) - core.collections
         A key-value mapping."""
      output

test-format-search-results-empty:
  output := DocFormatter.format-search-results {"results": [], "total": 0} --query="xyz"

  expect-equals """
      # Search Results for "xyz"

      No results found."""
      output

test-format-element-class:
  element := {
    "name": "List",
    "kind": "class",
    "library": "core.collections",
    "toitdoc": make-toitdoc "A growable list of elements.",
    "members": [
      {
        "name": "add",
        "kind": "method",
        "toitdoc": make-toitdoc "Adds the given value to the list.",
        "parameters": [],
      },
      {
        "name": "remove",
        "kind": "method",
        "toitdoc": make-toitdoc "Removes the value from the list.",
        "parameters": [],
      },
    ],
  }

  output := DocFormatter.format-element element

  expect-equals """
      # class List

      A growable list of elements.

      ## Members

      ### add (method)

      Adds the given value to the list.

      ### remove (method)

      Removes the value from the list."""
      output

test-format-element-class-overloaded:
  // Test that overloaded methods (same name, different signatures) are both shown.
  element := {
    "name": "List",
    "kind": "class",
    "library": "core.collections",
    "toitdoc": make-toitdoc "A growable list.",
    "members": [
      {
        "name": "add",
        "kind": "method",
        "toitdoc": make-toitdoc "Adds a single value.",
      },
      {
        "name": "add",
        "kind": "method",
        "toitdoc": make-toitdoc "Adds all values from another collection.",
      },
    ],
  }

  output := DocFormatter.format-element element

  expect-equals """
      # class List

      A growable list.

      ## Members

      ### add (method)

      Adds a single value.

      ### add (method)

      Adds all values from another collection."""
      output

test-format-element-function:
  element := {
    "name": "sort",
    "kind": "function",
    "library": "core.collections",
    "toitdoc": make-toitdoc "Sorts the given list.",
  }

  output := DocFormatter.format-element element

  expect-equals """
      # function sort

      Sorts the given list."""
      output

test-format-toitdoc-text:
  toitdoc := make-toitdoc "Hello world."
  output := DocFormatter.format-toitdoc toitdoc

  expect-equals "Hello world." output

test-format-toitdoc-code:
  toitdoc := make-toitdoc-expressions [
    DocCode --text="my-variable",
  ]
  output := DocFormatter.format-toitdoc toitdoc

  expect-equals "`my-variable`" output

test-format-toitdoc-link:
  toitdoc := make-toitdoc-expressions [
    DocLink --text="Click here" --url="https://example.com",
  ]
  output := DocFormatter.format-toitdoc toitdoc

  expect-equals "[Click here](https://example.com)" output

test-format-toitdoc-code-section:
  toitdoc := make-toitdoc-statements [
    DocCodeSection --text="x := 42",
  ]
  output := DocFormatter.format-toitdoc toitdoc

  expect-equals """
      ```
      x := 42
      ```"""
      output

test-format-toitdoc-itemized:
  toitdoc := make-toitdoc-statements [
    DocItemized --items=[
      DocItem --statements=[
        DocParagraph --expressions=[DocText --text="First item"],
      ],
      DocItem --statements=[
        DocParagraph --expressions=[DocText --text="Second item"],
      ],
    ],
  ]
  output := DocFormatter.format-toitdoc toitdoc

  expect-equals """
      - First item
      - Second item"""
      output

test-format-toitdoc-null:
  output := DocFormatter.format-toitdoc null

  expect-equals "" output
