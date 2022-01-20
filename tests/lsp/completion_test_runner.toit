// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .location_compiler_test_runner_base
import .lsp_client show LspClient
import expect show *

map_completion_kind kind -> string:
  kind = kind or -1
  // From: https://microsoft.github.io/language-server-protocol/specification#textDocument_completion
  mapping := {
    -1: "None",
    1: "Text",
    2: "Method",
    3: "Function",
    4: "Constructor",
    5: "Field",
    6: "Variable",
    7: "Class",
    8: "Interface",
    9: "Module",
    10: "Property",
    11: "Unit",
    12: "Value",
    13: "Enum",
    14: "Keyword",
    15: "Snippet",
    16: "Color",
    17: "File",
    18: "Reference",
    19: "Folder",
    20: "EnumMember",
    21: "Constant",
    22: "Struct",
    23: "Event",
    24: "Operator",
    25: "TypeParameter",
  }
  return mapping[kind]

class CompletionTestRunner extends LocationCompilerTestRunner:
  parse_test_lines lines:
    expected_completions := []
    unexpected_completions := []

    lines.do: |line|
      if line.trim == "+": continue.do
      if line.trim == "-": continue.do

      plus_index := line.index_of "+ "
      if plus_index >= 0:
        processed_expected_line := (line.copy (plus_index + 2)).trim --right ", "
        expected_completions.add_all (processed_expected_line.split ", ")
        continue.do

      minus_index := line.index_of "- "
      if minus_index >= 0:
        processed_unexpected_line := (line.copy (minus_index + 2)).trim --right ", "
        unexpected_completions.add_all (processed_unexpected_line.split ", ")

    return [expected_completions, unexpected_completions]

  send_request client/LspClient test_path line reader:
    response := client.send_completion_request --path=test_path line reader
    result := {:}
    response.do: |completion|
      label := completion["label"]
      kind := completion.get "kind"
      result[label] = map_completion_kind kind
    return result

  check_result actual test_data locations:
    expected   := test_data[0]
    unexpected := test_data[1]

    expected.do:
      hash_index := it.index_of "#"
      expected_name /string  := ?
      expected_kind /string? := ?
      if hash_index >= 0:
        expected_name = it.copy 0 hash_index
        expected_kind = it.copy (hash_index + 1)
      else:
        expected_name = it
        expected_kind = null
      if not actual.contains expected_name:
        print "Missing completion: $it"
      expect (actual.contains expected_name)
      if expected_kind:
        expect_equals expected_kind actual[expected_name]

    if unexpected.contains "*":
      expect_equals 1 unexpected.size
      expect_equals expected.size actual.size
    else:
      unexpected.do:
        if actual.contains it:
          print "Should not be contained: $it"
        expect (not actual.contains it)


main args:
  (CompletionTestRunner).run args
