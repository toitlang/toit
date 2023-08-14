// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .location-compiler-test-runner-base
import expect show *
import .lsp-client show LspClient
import .utils

class GotoDefinitionRunner extends LocationCompilerTestRunner:
  parse-test-lines lines:
    line  := lines[0]
    open  := line.index-of "["
    close := line.index-of "]"
    comma-separated-list := line.copy (open + 1) close
    if comma-separated-list == "": return []

    location-names := comma-separated-list.split ", "
    return location-names

  send-request client/LspClient test-path line reader:
    response := client.send-goto-definition-request --path=test-path line reader
    return response.map: |definition|
      uri := definition["uri"]
      path := client.to-path uri
      range := definition["range"]
      start-line := range["start"]["line"]
      start-char := range["start"]["character"]
      Location path start-line start-char

  check-core-definition core-lib-entry actuals:
    assert: core-lib-entry.starts-with "core."
    target := core-lib-entry.trim --left "core."
    expect
      actuals.any:
        path-slash := it.path.replace --all "\\" "/"
        path-slash.ends-with "core/$(target).toit"
          and it.column == 0
          and it.line == 0

  check-result actual test-data locations:
    if test-data.size != actual.size:
      print "Not same size:"
      print "test_data: $test-data"
      print "actual: $actual"
    expect-equals test-data.size actual.size

    test-data.do:
      // Special case `core.*`, since we don't want to change the actual
      // core library files.
      if it.starts-with "core.":
        check-core-definition it actual
      else:
        expect (actual.contains locations[it])

main args:
  (GotoDefinitionRunner).run args
