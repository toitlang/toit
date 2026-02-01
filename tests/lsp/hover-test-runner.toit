// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .location-compiler-test-runner-base
import expect show *
import .lsp-client show LspClient
import .utils

import host.file

class HoverRunner extends LocationCompilerTestRunner:
  parse-test-lines lines:
    return (lines.join "\n").trim

  send-request client/LspClient test-path line column:
    response := client.send-hover-request --path=test-path line column
    if not response: return []
    contents := response["contents"]
    if contents is Map: contents = contents["value"]
    else if contents is List: contents = (contents.map: it["value"]).join "\n"
    return [contents]

  check-result actual test-data locations:
    if actual.is-empty:
      expect-equals test-data ""
      return

    expect-equals 1 actual.size
    actual-string := actual[0]
    
    msg := "Expected <$test-data> Actual <$actual-string.trim>\n"
    file.write-contents --path="/tmp/test_debug.txt" msg

    expect-equals test-data actual-string.trim

main args:
  print "Args: $args"
  exception := catch:
    (HoverRunner).run args
    file.write-contents --path="/tmp/test_result.txt" "PASS"
  if exception:
    file.write-contents --path="/tmp/test_result.txt" "FAIL: $exception"
