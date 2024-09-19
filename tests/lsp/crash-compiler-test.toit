// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import host.directory
import expect show *
import host.file
import monitor

main args:
  run-client-test args
    --use-mock
    --pre-initialize=: it.configuration["shouldWriteReproOnCrash"] = true:
    test --expect-repro it

  run-client-test args
    --use-mock
    --pre-initialize=: it.configuration["shouldWriteReproOnCrash"] = false:
    test --no-expect-repro it

test --expect-repro/bool client/LspClient:
  mock-compiler := MockCompiler client

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
  did-create-repro := false

  client.install-handler "window/showMessage"::
    print "received crash showMessage"
    message := it["message"]
    expect (message.contains "Compiler crashed")
    expect (message.contains "/tmp/")
    repro-path := message.copy (message.index-of "/tmp/")
    expect (file.is-file repro-path)
    did-create-repro = true
    file.delete repro-path
    semaphore.up

  client.install-handler "window/logMessage"::
    print "received crash logMessage"
    message := it["message"]
    expect (message.contains "Compiler crashed")
    semaphore.up

  print "simulating a crash"
  client.send-did-change --path=protocol1 "foo"

  print "making sure the crash report was received."
  semaphore.down
  expect-equals expect-repro did-create-repro
