// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client
import .mock-compiler
import ...tools.lsp.server.server show CRASH-REPORT-RATE-LIMIT-MS
import host.directory
import expect show *
import host.file
import monitor

main args:
  run-client-test args
      --use-mock
      // We are modifying LSP server internal state. As such, we can't run
      //   the server as a separate process.
      --no-spawn-process:
    test-rate-limiting it --with-server-process

  print "All done"

  // Since we didn't ask the servers to exit, they are still running, waiting
  //   for RPC calls.
  exit 0

test-rate-limiting client/LspClient --with-server-process/bool=false:
  mock-compiler := MockCompiler client

  client.send-reset-crash-rate-limit

  protocol1 := "$(directory.cwd)/protocol1.toit"
  protocol2 := "$(directory.cwd)/protocol2.toit"
  protocol3 := "$(directory.cwd)/protocol3.toit"
  files-to-open := [
    [protocol1, 0],
    [protocol2, 1],
    [protocol3, 0],
  ]

  files-to-open.do: | test |
    path := test[0]
    print "opening $path"
    client.send-did-open --path=path

  print "sending mock for analyze"
  mock-compiler.set-analysis-result "CRASH\n"

  semaphore := monitor.Semaphore

  crashes-reported := 0

  client.install-handler "window/showMessage"::
    message := it["message"]
    expect (message.contains "Compiler crashed")
    expect (message.contains "/tmp/")
    repro-path := message.copy (message.index-of "/tmp/")
    expect (file.is-file repro-path)
    file.delete repro-path
    crashes-reported++
    semaphore.up

  print "simulating crash"
  client.send-did-change --path=protocol1 "foo"
  semaphore.down
  expect-equals 1 crashes-reported

  print "trying again. The rate limiter should kick in."
  client.send-did-change --path=protocol1 "foo"
  expect-equals 1 crashes-reported

  if with-server-process:
    // Simulate a crash some seconds ago.
    expect client.server.last-crash-report-time_ != null
    client.server.last-crash-report-time_ = Time.monotonic-us - CRASH-REPORT-RATE-LIMIT-MS * 1_000 - 1
  else:
    client.send-reset-crash-rate-limit

    print "simulating crash again"
    client.send-did-change --path=protocol1 "foo"
    semaphore.down
    expect-equals 2 crashes-reported
