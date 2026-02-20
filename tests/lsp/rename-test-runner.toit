// Copyright (C) 2026 Toitware ApS.
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
      // Read the expected reference count.
      if i >= lines.size: continue
      count-line := lines[i].trim
      if count-line == "*/":
        // No expected count given; skip.
        continue
      expected-count := int.parse count-line
      i++
      // Skip the closing */.
      while i < lines.size and not lines[i].starts-with "*/":
        i++

      client.send-did-change --path=test-path content
      response := client.send-rename-request --path=test-path test-line-index column "new-name"
      if expected-count == 0:
        expect-null response
      else:
        expect-not-null response
        changes := response["changes"]
        total-edits := 0
        changes.do: |uri edits|
          edits.do: |edit|
            expect-equals "new-name" edit["newText"]
            total-edits++
        expect-equals expected-count total-edits
