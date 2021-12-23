// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import .mock_compiler
import host.directory
import expect show *
import host.file
import monitor

main args:
  run_client_test args
    --use_mock
    --pre_initialize=: it.configuration["shouldWriteReproOnCrash"] = true:
    test --expect_repro it
  run_client_test args
    --use_toitlsp
    --use_mock
    --pre_initialize=: it.configuration["shouldWriteReproOnCrash"] = true:
    test --expect_repro it

  run_client_test args
    --use_mock
    --pre_initialize=: it.configuration["shouldWriteReproOnCrash"] = false:
    test --no-expect_repro it
  run_client_test args
    --use_toitlsp
    --use_mock
    --pre_initialize=: it.configuration["shouldWriteReproOnCrash"] = false:
    test --no-expect_repro it

test --expect_repro/bool client/LspClient:
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
  mock_compiler.set_analysis_result "CRASH\n"

  semaphore := monitor.Semaphore
  did_create_repro := false

  client.install_handler "window/showMessage"::
    print "received crash showMessage"
    message := it["message"]
    expect (message.contains "Compiler crashed")
    expect (message.contains "/tmp/")
    repro_path := message.copy (message.index_of "/tmp/")
    expect (file.is_file repro_path)
    did_create_repro = true
    file.delete repro_path
    semaphore.up

  client.install_handler "window/logMessage"::
    print "received crash logMessage"
    message := it["message"]
    expect (message.contains "Compiler crashed")
    semaphore.up

  print "simulating a crash"
  client.send_did_change --path=protocol1 "foo"

  print "making sure the crash report was received."
  semaphore.down
  expect_equals expect_repro did_create_repro
