// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *
import host.file

main args:
  run-client-test args: test it

class TestCase:
  line ::= ?
  column ::= ?
  length ::= ?
  type ::= ?
  modifiers ::= ?

  constructor .line .column .length .type .modifiers:

test client/LspClient:
  test-cases := []

  test-file := "$(directory.cwd)/semantic-tokens.toit"
  content := (file.read-contents test-file).to-string
  lines := (content.trim --right "\n").split "\n"
  for i := 0; i < lines.size; i++:
    line /string := lines[i]
    is-test-line := false
    if line.starts-with "/*" and not line.starts-with "/**":
      test-line-index := i - 1
      test-line := lines[test-line-index]
      if not line.contains "^":
        // This should only happen if we want to have a test/location at the
        // beginning of the line (or if this is a location entry).
        i++
        if i == lines.size: continue
        line = lines[i]
      if not line.contains "^": continue

      column := line.index-of "^"
      range-end := (line.index-of --last "~" --if-absent=:column) + 1
      length := range-end - column

      i++
      semantic-type := lines[i++].trim
      semantic-modifiers := ?
      if lines[i].starts-with "*/":
        semantic-modifiers = []
      else:
        semantic-modifiers = (lines[i].trim.split ",").map: it.trim

      test-cases.add
          TestCase test-line-index column length semantic-type semantic-modifiers

  initialize-result := client.initialize-result
  capabilities := initialize-result["capabilities"]
  legend := capabilities["semanticTokensProvider"]["legend"]
  token-types := legend["tokenTypes"]
  token-modifiers := legend["tokenModifiers"]

  response := client.send-semantic-tokens-request --path=test-file
  encoded-tokens := response["data"]

  test-index := 0

  i := 0
  last-line := 0
  last-column := 0
  while i < encoded-tokens.size and test-index < test-cases.size:
    line-delta := encoded-tokens[i++]
    column-delta := encoded-tokens[i++]
    length := encoded-tokens[i++]
    encoded-type := encoded-tokens[i++]
    encoded-modifiers := encoded-tokens[i++]

    line := last-line + line-delta
    last-line = line
    column := line-delta == 0 ? last-column + column-delta : column-delta
    last-column = column
    type := token-types[encoded-type]
    modifiers := []
    j := 0
    while encoded-modifiers != 0:
      if encoded-modifiers & 1 != 0: modifiers.add token-modifiers[j]
      j++
      encoded-modifiers >>= 1

    test-case /TestCase := test-cases[test-index]

    expect (line <= test-case.line)
    if line < test-case.line: continue
    if column < test-case.column: continue

    test-index++
    expect-equals test-case.column column
    expect-equals test-case.length length
    expect-equals test-case.type type
    expected-modifiers := test-case.modifiers
    expect-equals expected-modifiers.size modifiers.size
    // There are very few modifiers, so doing the quadratic approach doesn't hurt.
    expected-modifiers.do: expect (modifiers.contains it)

  expect test-index >= test-cases.size
