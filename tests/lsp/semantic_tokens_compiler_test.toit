// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *
import host.file

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

class TestCase:
  line ::= ?
  column ::= ?
  length ::= ?
  type ::= ?
  modifiers ::= ?

  constructor .line .column .length .type .modifiers:

test client/LspClient:
  test_cases := []

  test_file := "$(directory.cwd)/semantic_tokens.toit"
  content := (file.read_content test_file).to_string
  lines := (content.trim --right "\n").split "\n"
  for i := 0; i < lines.size; i++:
    line /string := lines[i]
    is_test_line := false
    if line.starts_with "/*" and not line.starts_with "/**":
      test_line_index := i - 1
      test_line := lines[test_line_index]
      if not line.contains "^":
        // This should only happen if we want to have a test/location at the
        // beginning of the line (or if this is a location entry).
        i++
        if i == lines.size: continue
        line = lines[i]
      if not line.contains "^": continue

      column := line.index_of "^"
      range_end := (line.index_of --last "~" --if_absent=:column) + 1
      length := range_end - column

      i++
      semantic_type := lines[i++].trim
      semantic_modifiers := ?
      if lines[i].starts_with "*/":
        semantic_modifiers = []
      else:
        semantic_modifiers = (lines[i].trim.split ",").map: it.trim

      test_cases.add
          TestCase test_line_index column length semantic_type semantic_modifiers

  initialize_result := client.initialize_result
  capabilities := initialize_result["capabilities"]
  legend := capabilities["semanticTokensProvider"]["legend"]
  token_types := legend["tokenTypes"]
  token_modifiers := legend["tokenModifiers"]

  response := client.send_semantic_tokens_request --path=test_file
  encoded_tokens := response["data"]

  test_index := 0

  i := 0
  last_line := 0
  last_column := 0
  while i < encoded_tokens.size and test_index < test_cases.size:
    line_delta := encoded_tokens[i++]
    column_delta := encoded_tokens[i++]
    length := encoded_tokens[i++]
    encoded_type := encoded_tokens[i++]
    encoded_modifiers := encoded_tokens[i++]

    line := last_line + line_delta
    last_line = line
    column := line_delta == 0 ? last_column + column_delta : column_delta
    last_column = column
    type := token_types[encoded_type]
    modifiers := []
    j := 0
    while encoded_modifiers != 0:
      if encoded_modifiers & 1 != 0: modifiers.add token_modifiers[j]
      j++
      encoded_modifiers >>= 1

    test_case /TestCase := test_cases[test_index]

    expect (line <= test_case.line)
    if line < test_case.line: continue
    if column < test_case.column: continue

    test_index++
    expect_equals test_case.column column
    expect_equals test_case.length length
    expect_equals test_case.type type
    expected_modifiers := test_case.modifiers
    expect_equals expected_modifiers.size modifiers.size
    // There are very few modifiers, so doing the quadratic approach doesn't hurt.
    expected_modifiers.do: expect (modifiers.contains it)

  expect test_index >= test_cases.size
