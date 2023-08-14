// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import expect show *
import monitor

main args:
  run-client-test args --use-mock: test it
  run-client-test --use-toitlsp args --use-mock: test it

test client/LspClient:
  // We want to cancel the request before it has finished, so we
  //   must not automatically wait for idle.
  client.always-wait-for-idle = false
  mock-compiler := MockCompiler client

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

  sleep-amount := 10
  cancel-succeeded := false
  while sleep-amount < 1000_000:
    mock-compiler.set-completion-result
      "SLOW\n$sleep-amount\nfoo\n-1\nbar\n-1\n"
    client.wait-for-idle

    completions := client.send-completion-request --uri=uri 1 2 --id-callback=:
      print "canceling $it"
      client.send-cancel it
    if completions.contains "code":
      expect-equals -32800 completions["code"]
      cancel-succeeded = true
      break
    else:
      print "Got a response: $completions"
    sleep-amount *= 2
  expect cancel-succeeded

  client.wait-for-idle

  // Now try to cancel a request where we were too slow for the cancel.
  mock-compiler.set-completion-result
    "foo\n-1\nbar\n-1\n"
  id := null
  completions := client.send-completion-request --uri=uri 1 2 --id-callback=:
    id = it
  print "cancelling request that has already finished"
  client.send-cancel id
  // Just shouldn't do anything.
  client.wait-for-idle
