// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that analyses triggered by 'didChange' are debounced.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import expect show *

DEBOUNCE-MS ::= 500

main args:
  run-client-test
      args
      --use-mock
      --pre-initialize=: it.configuration["analysisDebounceMs"] = DEBOUNCE-MS:
    test it

test client/LspClient:
  mock-compiler := MockCompiler client

  uri := "untitled:Untitled-1"
  path := client.to-path uri

  mock-compiler.set-mock-data --path=path (MockData [] [])
  mock-compiler.set-analysis-result (mock-compiler.build-analysis-answer --path=path)

  // Every analysis of the document publishes its diagnostics. Count them.
  diagnostics-count := 0
  client.install-handler "textDocument/publishDiagnostics":: | params/Map |
    if params["uri"] == uri: diagnostics-count++

  // Opening a document is analyzed right away.
  client.send-did-open --uri=uri --text="Ignored content"
  expect-equals 1 diagnostics-count

  // A burst of changes leads to two analyses: one for the first change, and
  // one once the changes have stopped.
  client.always-wait-for-idle = false
  5.repeat:
    client.send-did-change --uri=uri "Ignored content $it"
    sleep --ms=(DEBOUNCE-MS / 5)
  client.always-wait-for-idle = true
  // The pending analysis must count as work in progress: the server must not
  // report idle before it has run.
  client.wait-for-idle
  expect-equals 3 diagnostics-count

  // Changes that are further apart than the debounce delay each start a new
  // burst and are thus analyzed individually.
  client.always-wait-for-idle = false
  3.repeat:
    client.send-did-change --uri=uri "Ignored content again $it"
    sleep --ms=(DEBOUNCE-MS * 2)
  client.always-wait-for-idle = true
  client.wait-for-idle
  expect-equals 6 diagnostics-count
