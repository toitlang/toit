// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import host.pipe
import .lsp-client show LspClient run-client-test
import .utils
import system
import system show platform

is-absolute_ path/string -> bool:
  if path.starts-with "/": return true
  if platform != system.PLATFORM-WINDOWS: return false
  return path.size > 1 and path[1] == ':'

abstract class LocationCompilerTestRunner:
  abstract parse-test-lines lines
  abstract send-request client/LspClient test-path/string line/int column/int
  abstract check-result actual test-data locations

  run args:
    test-path := args[0]
    args = args.copy 1
    if not is-absolute_ test-path:
      throw "test-path must be absolute (and canonicalized): $test-path"

    locations := extract-locations test-path

    run-client-test args: test it test-path locations

  test client/LspClient test-path/string locations/Map:
    content := (file.read-content test-path).to-string

    client.send-did-open --path=test-path --text=content

    lines := (content.trim --right "\n").split "\n"
    lines = lines.map --in-place: it.trim --right "\r"
    for i := 0; i < lines.size; i++:
      line := lines[i]
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

        range-end := (line.index-of --last "~") + 1
        alternative-content := null

        if not range-end == 0:
          replacement-line := (test-line.copy 0 column) + (test-line.copy range-end)
          alternative-content = combine-and-replace lines test-line-index replacement-line

        test-data-lines := []
        i++
        while not lines[i].starts-with "*/":
          test-data-lines.add lines[i++]
        test-data := parse-test-lines test-data-lines

        client.send-did-change --path=test-path content
        response := send-request client test-path test-line-index column
        check-result response test-data locations

        if alternative-content != null:
          client.send-did-change --path=test-path alternative-content
          alternative-response := send-request client test-path test-line-index column
          check-result alternative-response test-data locations
