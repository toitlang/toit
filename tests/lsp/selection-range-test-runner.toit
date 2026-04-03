// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import .utils
import expect show *
import host.file

main args:
  test-path := args[0]
  args = args.copy 1

  run-client-test args: test it test-path

test client/LspClient test-path/string:
  content := (file.read-contents test-path).to-string
  client.send-did-open --path=test-path --text=content

  lines := (content.trim --right "\n").split "\n"
  lines = lines.map --in-place: it.trim --right "\r"
  for i := 0; i < lines.size; i++:
    line := lines[i]
    if line.starts-with "/*" and not line.starts-with "/**":
      test-line-index := i - 1
      if i + 1 >= lines.size: continue
      next-line := lines[i + 1]
      if not next-line.contains "^": continue
      column := next-line.index-of "^"
      // Skip past the caret line.
      i += 2
      // Read expected ranges, one per line, until we hit "*/".
      expected-ranges := []
      while i < lines.size:
        expected-line := lines[i].trim
        if expected-line == "*/": break
        if expected-line != "":
          expected-ranges.add expected-line
        i++

      if expected-ranges.is-empty: continue

      client.send-did-change --path=test-path content
      positions := [{"line": test-line-index, "character": column}]
      response := client.send-selection-range-request --path=test-path positions
      expect-not-null response
      expect-equals 1 response.size

      selection-range := response[0]
      expected-ranges.do: | expected/string |
        expect (selection-range != null)
            --message="Expected range $expected but selection range chain ended"
        range := selection-range["range"]
        actual := range-to-string range
        expect-equals expected actual
        selection-range = selection-range.get "parent"

/**
Converts a range map to its string representation.

The format is "[line:col]-[line:col]" with 0-based line and column.
*/
range-to-string range/Map -> string:
  start := range["start"]
  end := range["end"]
  return "[$start["line"]:$start["character"]]-[$end["line"]:$end["character"]]"
