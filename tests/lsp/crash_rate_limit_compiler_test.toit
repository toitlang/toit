// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client
import .mock_compiler
import ...tools.lsp.server.server show CRASH_REPORT_RATE_LIMIT_MS
import host.directory
import expect show *
import host.file
import monitor

main args:
  run_client_test args
      --use_mock
      // We are modifying LSP server internal state. As such, we can't run
      //   the server as a separate process.
      --no-spawn_process:
    test_rate_limiting it --with_server_process

  run_client_test args
      --use_mock
      --use_toitlsp:
    test_rate_limiting it

  print "All done"

  // Since we didn't ask the servers to exit, they are still running, waiting
  //   for RPC calls.
  exit 0

test_rate_limiting client/LspClient --with_server_process/bool=false:
  mock_compiler := MockCompiler client

  client.send_reset_crash_rate_limit

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

  crashes_reported := 0

  client.install_handler "window/showMessage"::
    message := it["message"]
    expect (message.contains "Compiler crashed")
    expect (message.contains "/tmp/")
    repro_path := message.copy (message.index_of "/tmp/")
    expect (file.is_file repro_path)
    file.delete repro_path
    crashes_reported++
    semaphore.up

  print "simulating crash"
  client.send_did_change --path=protocol1 "foo"
  semaphore.down
  expect_equals 1 crashes_reported

  print "trying again. The rate limiter should kick in."
  client.send_did_change --path=protocol1 "foo"
  expect_equals 1 crashes_reported

  if with_server_process:
    // Simulate a crash some seconds ago.
    expect client.server.last_crash_report_time_ != null
    client.server.last_crash_report_time_ = Time.monotonic_us - CRASH_REPORT_RATE_LIMIT_MS * 1_000 - 1
  else:
    client.send_reset_crash_rate_limit

    print "simulating crash again"
    client.send_did_change --path=protocol1 "foo"
    semaphore.down
    expect_equals 2 crashes_reported
