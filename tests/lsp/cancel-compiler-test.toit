// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import expect show *
import monitor

main args:
  run-client-test args --use-mock: | client mock-compiler |
    test client mock-compiler

test client/LspClient mock-compiler/MockCompiler:
  // We want to cancel the request before it has finished, so we
  //   must not automatically wait for idle.
  client.always-wait-for-idle = false

  uri := "untitled:Untitled-1"
  path := client.to-path uri

  // Install a response for diagnostics.
  diagnostics := []
  deps := []
  mock-data := MockData diagnostics deps
  mock-compiler.set-mock-data --path=path mock-data
  answer := mock-compiler.build-analysis-answer --path=path
  mock-compiler.set-analysis-result answer

  client.send-did-open --uri=uri --text="""
    Completely ignored content.
  """

  // The compiler waits for us at the rendezvous, so the cancel is guaranteed
  // to arrive while the request is still running.
  mock-compiler.set-completion-result --sync
      "\n0\n0\n0\n0\nfoo\n-1\nbar\n-1\n"
  client.wait-for-idle

  completions := client.send-completion-request --uri=uri 1 2 --id-callback=: | id |
    // The compiler is now running and waits for us.
    mock-compiler.wait-for-waiting 1
    print "canceling $id"
    client.send-cancel id
  expect-equals -32800 completions["code"]

  // Canceling must kill the compiler. We never release it, so the server can
  // only become idle again if it killed the compiler.
  with-timeout --ms=5_000: client.wait-for-idle

  // Now try to cancel a request where we were too slow for the cancel.
  mock-compiler.set-completion-result
    "\n0\n0\n0\n0\nfoo\n-1\nbar\n-1\n"
  id := null
  completions = client.send-completion-request --uri=uri 1 2 --id-callback=:
    id = it
  print "cancelling request that has already finished"
  client.send-cancel id
  // Just shouldn't do anything.
  client.wait-for-idle

  // The server must still work afterwards.
  completions = client.send-completion-request --uri=uri 1 2
  expect-equals 2 completions.size
