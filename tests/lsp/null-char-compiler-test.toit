// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import host.file
import expect show *

main args:
  run-client-test args: test it

test client/LspClient:
  path := "$(directory.cwd)/null-char.toit"
  client.send-did-open --path=path
  diagnostics := client.diagnostics-for --path=path
  expect-equals 4 diagnostics.size

  content := (file.read-contents path).to-string
  untitled-uri := "untitled:Untitled-1"
  client.send-did-open --uri=untitled-uri --text=content
  diagnostics = client.diagnostics-for --path=path
  expect-equals 4 diagnostics.size
