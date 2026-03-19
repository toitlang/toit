// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .location-compiler-test-runner-base
import expect show *
import .lsp-client show LspClient
import .utils

class HoverRunner extends LocationCompilerTestRunner:
  parse-test-lines lines:
    // Support multi-line expected values.
    return lines.join "\n"

  send-request client/LspClient test-path line column:
    response := client.send-hover-request --path=test-path line column
    if response == null: return null
    contents := response["contents"]
    // The contents is a MarkupContent object with "kind" and "value".
    if contents is Map: return contents["value"]
    return contents

  check-result actual test-data locations:
    if test-data == "null":
      expect-null actual
    else if test-data.ends-with "...":
      expect (actual.starts-with (test-data.trim --right "..."))
    else:
      expect-equals test-data actual

main args:
  (HoverRunner).run args
