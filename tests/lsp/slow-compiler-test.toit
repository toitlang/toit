// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import expect show *
import monitor

main args:
  run-client-test args --use-mock: test it

test client/LspClient:
  // We want to send multiple requests overlapping each other, so we
  //   must not automatically wait for idle.
  client.always-wait-for-idle = false
  mock-compiler := MockCompiler client

  uri := "untitled:Untitled-1"
  path := client.to-path uri

  mutex := monitor.Mutex
  response-counter := 0
  last-clean-diagnostics := -1
  last-error-diagnostics := -1
  client.install-handler "textDocument/publishDiagnostics":: |params|
    // The mutex makes it cleaner to do the checks below with clean data.
    // Without any printing/logging we don't need it, but it's safer to
    //   prepare for such code.
    mutex.do:
      diagnostics-uri := params["uri"]
      if diagnostics-uri == uri:
        if params["diagnostics"].is-empty:
          last-clean-diagnostics = response-counter
        else:
          last-error-diagnostics = response-counter
        response-counter++

  sleep-us := 10
  first-diagnostics-was-ignored := false
  while sleep-us < 1000_000:
    deps := []
    error-diagnostics := [
      MockDiagnostic --path=path "Unresolved identifier: 'foo' RESPONSE FROM MOCK" 1 2 1 5,
    ]
    clean-diagnostics := []

    error-mock-data := MockData error-diagnostics deps
    mock-compiler.set-mock-data --path=path error-mock-data
    error-answer := mock-compiler.build-analysis-answer --delay-us=sleep-us --path=path

    clean-mock-data := MockData clean-diagnostics deps
    mock-compiler.set-mock-data --path=path clean-mock-data
    clean-answer := mock-compiler.build-analysis-answer --delay-us=sleep-us --path=path

    mock-compiler.set-analysis-result error-answer

    client.wait-for-idle

    current-response-counter := response-counter

    client.send-did-open --uri=uri --text="""
      Completely ignored content.
    """

    // Give the server a chance to launch the mock-compiler with the error-mock data.
    sleep --ms=sleep-us / 1000 / 2

    mock-compiler.set-analysis-result clean-answer

    client.send-did-change --uri=uri """
      Also completely ignored
    """

    client.wait-for-idle

    client.send-did-close --path=path

    mutex.do:
      expect last-clean-diagnostics >= current-response-counter
      // Sometimes the mock-update happened before the mock-compiler was run,
      //   and we get two clean diagnostics.
      // The test only succeeds if we end up with just one diagnostic.
      if response-counter == current-response-counter + 1:
        expect last-error-diagnostics < current-response-counter
        first-diagnostics-was-ignored = true
        break
    sleep-us *= 2
  expect first-diagnostics-was-ignored

  client.wait-for-idle
