// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import .mock_compiler
import expect show *
import monitor

main args:
  run_client_test args --use_mock: test it
  run_client_test --use_toitlsp args --use_mock: test it

test client/LspClient:
  // We want to cancel the request before it has finished, so we
  //   must not automatically wait for idle.
  client.always_wait_for_idle = false
  mock_compiler := MockCompiler client

  uri := "untitled:Untitled-1"
  path := client.to_path uri

  // Install a response for diagnostics.
  diagnostics := []
  deps := []
  mock_data := MockData diagnostics deps
  mock_compiler.set_mock_data --path=path mock_data
  answer := mock_compiler.build_analysis_answer --path=path
  mock_compiler.set_analysis_result answer

  client.send_did_open --uri=uri --text="""
    Completely ignored content.
  """

  sleep_amount := 10
  cancel_succeeded := false
  while sleep_amount < 1000_000:
    mock_compiler.set_completion_result
      "SLOW\n$sleep_amount\nfoo\n-1\nbar\n-1\n"
    client.wait_for_idle

    completions := client.send_completion_request --uri=uri 1 2 --id_callback=:
      print "canceling $it"
      client.send_cancel it
    if completions.contains "code":
      expect_equals -32800 completions["code"]
      cancel_succeeded = true
      break
    else:
      print "Got a response: $completions"
    sleep_amount *= 2
  expect cancel_succeeded

  client.wait_for_idle

  // Now try to cancel a request where we were too slow for the cancel.
  mock_compiler.set_completion_result
    "foo\n-1\nbar\n-1\n"
  id := null
  completions := client.send_completion_request --uri=uri 1 2 --id_callback=:
    id = it
  print "cancelling request that has already finished"
  client.send_cancel id
  // Just shouldn't do anything.
  client.wait_for_idle
