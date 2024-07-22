// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import .mock-compiler
import host.directory
import expect show *
import host.file
import monitor

binary-contains-string byte-array/ByteArray needle/string -> bool:
  bytes := needle.to-byte-array
  (byte-array.size - bytes.size).repeat: |offset|
    found := true
    for i := 0; i < bytes.size; i++:
      if byte-array[offset + i] != bytes[i]:
        found = false
        break
    if found: return true
  return false

main args:
  run-client-test args --use-mock: test it

test client/LspClient:
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
  mock-compiler.set-dump-file-names-result "CRASH\n$protocol1\n"

  semaphore := monitor.Semaphore

  crash-count := 0
  client.install-handler "window/showMessage"::
    message := it["message"]
    expect (message.contains "Compiler crashed")
    expect (message.contains "/tmp/")
    repro-path := message.copy (message.index-of "/tmp/")
    expect (file.is-file repro-path)
    content := file.read-content repro-path
    // We are only looking for "protocol1.toit" to avoid issues with Unicode characters.
    expect (binary-contains-string content "/protocol1.toit")
    file.delete repro-path
    crash-count++
    semaphore.up

  print "simulating crash"
  client.send-did-change --path=protocol1 "foo"

  expect-equals crash-count 1

  semaphore.down
  expect-equals crash-count 1  // Should not be necessary, but can't hurt.
