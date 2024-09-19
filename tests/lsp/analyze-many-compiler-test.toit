// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *
import host.file
import monitor

main args:
  run-client-test args: test it

test client/LspClient:
  protocol1 := "$(directory.cwd)/protocol1.toit"
  protocol2 := "$(directory.cwd)/protocol2.toit"
  protocol3 := "$(directory.cwd)/protocol3.toit"
  files-to-open-and-diagnostics := [
    [protocol1, 0],
    [protocol2, 1],
    [protocol3, 0],
  ]
  files-to-open := files-to-open-and-diagnostics.map: it[0]

  client.send-analyze-many --paths=files-to-open
  files-to-open-and-diagnostics.do:
    file := it[0]
    expected-diagnostics := it[1]
    diagnostics := client.diagnostics-for --path=file
    expect-equals expected-diagnostics diagnostics.size
