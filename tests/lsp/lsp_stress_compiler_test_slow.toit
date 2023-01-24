// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import services.arguments show *
import host.directory
import expect show *
import monitor
import host.pipe

main args:
  run_client_test args
    --pre_initialize=: it.configuration["timeoutMs"] = -1:  // No timeout
    test it
  run_client_test --use_toitlsp args
    --pre_initialize=: it.configuration["timeoutMs"] = -1:  // No timeout
    test it

test client/LspClient:
  RUN_TIME ::= 15_000_000
  CONCURRENT_REQUEST_COUNT ::= 8
  FILE_COUNT ::= 10

  client.always_wait_for_idle = false

  print "Sending open documents"
  for i := 0; i < FILE_COUNT; i++:
    pipe.stdout.write "."
    // Don't create the files in parallel, to avoid launching all the diagnostic
    // requests.
    client.send_did_open --uri="untitled:Untitled-$i" --text="""
      some_function: return 499
      some_other_function: return 42
      """
    client.wait_for_idle

  drive := platform == PLATFORM_WINDOWS ? "c:" : ""
  completion_document := "$drive/tmp/completion.toit"
  client.send_did_open --path=completion_document  --text="""
     completion_fun: return 499
     main: com
     """

  print "\nRequesting completions"

  start_time := Time.monotonic_us
  while Time.monotonic_us - start_time < RUN_TIME:
    semaphore := monitor.Semaphore
    CONCURRENT_REQUEST_COUNT.repeat:
      task::
        response := client.send_completion_request --path=completion_document 1 8
        expect (response.any: it["label"] == "completion_fun")
        semaphore.up

    CONCURRENT_REQUEST_COUNT.repeat:
      pipe.stdout.write "."
      semaphore.down

    pipe.stdout.write "\n"
  print "done"
