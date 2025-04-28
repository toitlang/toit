// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import ...tools.lsp.server.protocol.document-symbol as lsp
import .utils

import host.directory
import host.file
import expect show *

main args:
  run-client-test args:
    test-ranges it "$(directory.cwd)/outline2.toit"
    test-ranges it "$(directory.cwd)/outline2-non-empty-last.toit"

test-ranges client/LspClient outline-path/string:

  content := file.read-contents outline-path
  lines := content.to-string.split "\n"
  lines.map --in-place: it.replace --all "\r" ""

  expected-ranges := {:}
  start-line := -1
  start-char := -1
  to-end/bool := false
  current-name/string? := null
  for i := 0; i < lines.size; i++:
    line := lines[i]
    if line.contains "// vvv":
      start-line = i
      start-char = line.index-of "// vvv"
      line = line.trim
      line = line.trim --left "// vvv"
      to-end = line.contains "--to-end."
      line = line.trim --right "--to-end."
      current-name = line.trim
    if line.contains "// ^^^":
      end-line := i - 1
      end-char := lines[end-line].size
      expected-ranges[current-name] = [start-line, start-char, end-line, end-char]
  if to-end:
    if lines.last.size == 0:
      expected-ranges[current-name] = [start-line, start-char, lines.size - 2, lines[lines.size - 2].size]
    else:
      // Not 100% sure about this, but since the range is exclusive it could make sense.
      expected-ranges[current-name] = [start-line, start-char, lines.size, 0]

  client.send-did-open --path=outline-path
  outline-response := client.send-outline-request --path=outline-path

  verified-count := 0

  check-symbol/Lambda? := null
  check-symbol = :: | symbol/Map |
    name := symbol["name"]
    range := symbol["range"]
    if expected-ranges.contains name:
      expected-range := expected-ranges[name]
      if range["start"]["line"] != expected-range[0] or
         range["start"]["character"] != expected-range[1] or
         range["end"]["line"] != expected-range[2] or
         range["end"]["character"] != expected-range[3]:
        print "Expected range for $name: $expected-range, but got $range"
        throw "WRONG RANGE"
      verified-count++

    children := symbol.get "children"
    if children: children.do: check-symbol.call it

  outline-response.do: check-symbol.call it
  expect-equals expected-ranges.size verified-count
