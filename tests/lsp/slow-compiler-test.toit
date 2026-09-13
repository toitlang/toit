// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Tests that the diagnostics of an outdated analysis are discarded.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import expect show *
import monitor

main args:
  run-client-test args --use-mock: | client mock-compiler |
    test client mock-compiler

test client/LspClient mock-compiler/MockCompiler:
  // The analyses must overlap, so we must not wait for idle in between.
  client.always-wait-for-idle = false

  uri := "untitled:Untitled-1"
  path := client.to-path uri

  diagnostics-count := 0
  error-diagnostics-count := 0
  clean-diagnostics := monitor.Latch
  client.install-handler "textDocument/publishDiagnostics":: | params |
    if params["uri"] == uri:
      diagnostics-count++
      if params["diagnostics"].is-empty:
        if not clean-diagnostics.has-value: clean-diagnostics.set true
      else:
        error-diagnostics-count++

  deps := []
  error-diagnostics := [
    MockDiagnostic --path=path "Unresolved identifier: 'foo' RESPONSE FROM MOCK" 1 2 1 5,
  ]
  mock-compiler.set-mock-data --path=path (MockData error-diagnostics deps)
  error-answer := mock-compiler.build-analysis-answer --path=path
  mock-compiler.set-mock-data --path=path (MockData [] deps)
  clean-answer := mock-compiler.build-analysis-answer --path=path

  // The analysis of the 'didOpen' waits for us, and can thus not finish before
  // the change below has been analyzed.
  mock-compiler.set-analysis-result --sync error-answer
  client.send-did-open --uri=uri --text="""
    Completely ignored content.
  """
  mock-compiler.wait-for-waiting 1

  // The change starts a newer analysis, which finishes first.
  mock-compiler.set-analysis-result clean-answer
  client.send-did-change --uri=uri """
    Also completely ignored
  """
  clean-diagnostics.get

  // The outdated analysis must not publish its diagnostics anymore.
  mock-compiler.release-all
  client.always-wait-for-idle = true
  client.wait-for-idle
  expect-equals 0 error-diagnostics-count
  expect-equals 1 diagnostics-count
