// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *

main args:
  run-client-test args: test it

test client/LspClient:
  warning-path := "$(directory.cwd)/warning.toit"
  client.send-did-open --path=warning-path
  diagnostics := client.diagnostics-for --path=warning-path
  expect-equals 1 diagnostics.size
