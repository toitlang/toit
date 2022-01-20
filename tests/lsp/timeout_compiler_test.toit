// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import .mock_compiler
import host.directory
import expect show *
import host.file
import monitor

main args:
  run_client_test
      args
      --use_mock
      // Decrease the timeout a bit to make the test terminate faster.
      --pre_initialize=: it.configuration["timeoutMs"] = 500:
    test it
  run_client_test
      args
      --use_toitlsp
      --use_mock
      // Decrease the timeout a bit to make the test terminate faster.
      --pre_initialize=: it.configuration["timeoutMs"] = 500:
    test it

test client/LspClient:
  mock_compiler := MockCompiler client

  protocol1 := "$(directory.cwd)/protocol1.toit"
  protocol2 := "$(directory.cwd)/protocol2.toit"
  protocol3 := "$(directory.cwd)/protocol3.toit"
  files_to_open := [
    [protocol1, 0],
    [protocol2, 1],
    [protocol3, 0],
  ]

  files_to_open.do: | test |
    path := test[0]
    print "opening $path"
    client.send_did_open --path=path

  print "sending mock for analyze"
  mock_compiler.set_analysis_result "TIMEOUT\n"

  semaphore := monitor.Semaphore

  client.install_handler "window/showMessage"::
    print "received crash message"
    message := it["message"]
    expect (message.contains "Compiler crashed")
    expect (message.contains "/tmp/")
    repro_path := message.copy (message.index_of "/tmp/")
    expect (file.is_file repro_path)
    file.delete repro_path
    semaphore.up

  print "simulating a timeout"
  client.send_did_change --path=protocol1 "foo"

  print "making sure the crash report was received."
  semaphore.down
