// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .location-compiler-test-runner-base
import .lsp-client show LspClient
import expect show *

map-completion-kind kind -> string:
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
  parse-test-lines lines:
    expected-completions := []
    unexpected-completions := []

    lines.do: |line|
      if line.trim == "+": continue.do
      if line.trim == "-": continue.do

      plus-index := line.index-of "+ "
      if plus-index >= 0:
        processed-expected-line := (line.copy (plus-index + 2)).trim --right ", "
        expected-completions.add-all (processed-expected-line.split ", ")
        continue.do

      minus-index := line.index-of "- "
      if minus-index >= 0:
        processed-unexpected-line := (line.copy (minus-index + 2)).trim --right ", "
        unexpected-completions.add-all (processed-unexpected-line.split ", ")

    return [expected-completions, unexpected-completions]

  send-request client/LspClient test-path line reader:
    response := client.send-completion-request --path=test-path line reader
    result := {:}
    response.do: |completion|
      label := completion["label"]
      kind := completion.get "kind"
      result[label] = map-completion-kind kind
    return result

  check-result actual test-data locations:
    expected   := test-data[0]
    unexpected := test-data[1]

    expected.do:
      hash-index := it.index-of "#"
      expected-name /string  := ?
      expected-kind /string? := ?
      if hash-index >= 0:
        expected-name = it.copy 0 hash-index
        expected-kind = it.copy (hash-index + 1)
      else:
        expected-name = it
        expected-kind = null
      if not actual.contains expected-name:
        print "Missing completion: $it"
        print "Actual: $actual"
      expect (actual.contains expected-name)
      if expected-kind:
        expect-equals expected-kind actual[expected-name]

    if unexpected.contains "*":
      expect-equals 1 unexpected.size
      if expected.size != actual.size:
        print "Expected: $expected"
        print "Actual: $actual"
      expect-equals expected.size actual.size
    else:
      unexpected.do:
        if actual.contains it:
          print "Should not be contained: $it"
        expect (not actual.contains it)


main args:
  (CompletionTestRunner).run args
