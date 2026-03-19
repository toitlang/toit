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

import ...tools.mcp.formatter show DocFormatter

main:
  test-format-library-list
  test-format-library-list-empty
  test-format-search-results
  test-format-search-results-empty
  test-format-element-class
  test-format-element-function
  test-format-toitdoc-text
  test-format-toitdoc-code
  test-format-toitdoc-link
  test-format-toitdoc-code-section
  test-format-toitdoc-itemized
  test-format-toitdoc-null

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

/// Creates a toitdoc section with the given $expressions.
make-toitdoc-expressions expressions/List -> List:
  return [
    {
      "object_type": "section",
      "level": 0,
      "statements": [
        {
          "object_type": "statement_paragraph",
          "expressions": expressions,
        },
      ],
    },
  ]

/// Creates a toitdoc section with the given $statements.
make-toitdoc-statements statements/List -> List:
  return [
    {
      "object_type": "section",
      "level": 0,
      "statements": statements,
    },
  ]

test-format-library-list:
  entries := [
    {"name": "core", "path": ["core"], "modules": ["collections", "utils"]},
    {"name": "net", "path": ["net"], "modules": ["http", "tcp"]},
  ]

  output := DocFormatter.format-library-list entries

  expect (output.contains "core")
  expect (output.contains "net")
  expect (output.contains "collections")
  expect (output.contains "utils")
  expect (output.contains "http")
  expect (output.contains "tcp")

test-format-library-list-empty:
  output := DocFormatter.format-library-list []

  // Should not crash and should indicate no libraries.
  expect (output.contains "No libraries" or output.contains "no libraries" or output.contains "No results")

test-format-search-results:
  results := [
    {"name": "List", "kind": "class", "library": "core.collections", "summary": "A growable list."},
    {"name": "Map", "kind": "class", "library": "core.collections", "summary": "A key-value mapping."},
  ]

  output := DocFormatter.format-search-results results --query="collection"

  expect (output.contains "collection")
  expect (output.contains "List")
  expect (output.contains "Map")
  expect (output.contains "class")
  expect (output.contains "core.collections")
  expect (output.contains "A growable list.")
  expect (output.contains "A key-value mapping.")

test-format-search-results-empty:
  output := DocFormatter.format-search-results [] --query="xyz"

  expect (output.contains "xyz")
  expect (output.contains "No results found")

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

  expect (output.contains "List")
  expect (output.contains "class")
  expect (output.contains "A growable list of elements.")
  expect (output.contains "add")
  expect (output.contains "remove")
  expect (output.contains "method")
  expect (output.contains "Adds the given value to the list.")
  expect (output.contains "Removes the value from the list.")

test-format-element-function:
  element := {
    "name": "sort",
    "kind": "function",
    "library": "core.collections",
    "toitdoc": make-toitdoc "Sorts the given list.",
  }

  output := DocFormatter.format-element element

  expect (output.contains "sort")
  expect (output.contains "function")
  expect (output.contains "Sorts the given list.")

test-format-toitdoc-text:
  toitdoc := make-toitdoc "Hello world."
  output := DocFormatter.format-toitdoc toitdoc

  expect (output.contains "Hello world.")

test-format-toitdoc-code:
  toitdoc := make-toitdoc-expressions [
    {"object_type": "expression_code", "text": "my-variable"},
  ]
  output := DocFormatter.format-toitdoc toitdoc

  expect (output.contains "`my-variable`")

test-format-toitdoc-link:
  toitdoc := make-toitdoc-expressions [
    {"object_type": "expression_link", "text": "Click here", "url": "https://example.com"},
  ]
  output := DocFormatter.format-toitdoc toitdoc

  expect (output.contains "[Click here](https://example.com)")

test-format-toitdoc-code-section:
  toitdoc := make-toitdoc-statements [
    {"object_type": "statement_code_section", "text": "x := 42"},
  ]
  output := DocFormatter.format-toitdoc toitdoc

  expect (output.contains "```")
  expect (output.contains "x := 42")

test-format-toitdoc-itemized:
  toitdoc := make-toitdoc-statements [
    {
      "object_type": "statement_itemized",
      "items": [
        {
          "object_type": "statement_item",
          "statements": [
            {
              "object_type": "statement_paragraph",
              "expressions": [
                {"object_type": "expression_text", "text": "First item"},
              ],
            },
          ],
        },
        {
          "object_type": "statement_item",
          "statements": [
            {
              "object_type": "statement_paragraph",
              "expressions": [
                {"object_type": "expression_text", "text": "Second item"},
              ],
            },
          ],
        },
      ],
    },
  ]
  output := DocFormatter.format-toitdoc toitdoc

  expect (output.contains "First item")
  expect (output.contains "Second item")
  // Should use bullet markers.
  expect (output.contains "- " or output.contains "* ")

test-format-toitdoc-null:
  output := DocFormatter.format-toitdoc null

  expect-equals "" output
