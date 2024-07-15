// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *
import monitor
import host.pipe
import system
import system show platform

main args:
  run-client-test args
    --pre-initialize=: it.configuration["timeoutMs"] = -1:  // No timeout
    test it

test client/LspClient:
  RUN-TIME ::= 15_000_000
  CONCURRENT-REQUEST-COUNT ::= 8
  FILE-COUNT ::= 10

  client.always-wait-for-idle = false

  print "Sending open documents"
  for i := 0; i < FILE-COUNT; i++:
    pipe.stdout.write "."
    // Don't create the files in parallel, to avoid launching all the diagnostic
    // requests.
    client.send-did-open --uri="untitled:Untitled-$i" --text="""
      some-function: return 499
      some-other_function: return 42
      """
    client.wait-for-idle

  drive := platform == system.PLATFORM-WINDOWS ? "c:" : ""
  completion-document := "$drive/tmp/completion.toit"
  client.send-did-open --path=completion-document  --text="""
     completion-fun: return 499
     main: com
     """

  print "\nRequesting completions"

  start-time := Time.monotonic-us
  while Time.monotonic-us - start-time < RUN-TIME:
    semaphore := monitor.Semaphore
    CONCURRENT-REQUEST-COUNT.repeat:
      task::
        response := client.send-completion-request --path=completion-document 1 8
        expect (response.any: it["label"] == "completion-fun")
        semaphore.up

    CONCURRENT-REQUEST-COUNT.repeat:
      pipe.stdout.write "."
      semaphore.down

    pipe.stdout.write "\n"
  print "done"
