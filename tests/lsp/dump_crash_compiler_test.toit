// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import .mock_compiler
import host.directory
import expect show *
import host.file
import monitor

binary_contains_string byte_array/ByteArray needle/string -> bool:
  bytes := needle.to_byte_array
  (byte_array.size - bytes.size).repeat: |offset|
    found := true
    for i := 0; i < bytes.size; i++:
      if byte_array[offset + i] != bytes[i]:
        found = false
        break
    if found: return true
  return false

main args:
  run_client_test args --use_mock: test it
  run_client_test args --use_toitlsp --use_mock: test it

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
  mock_compiler.set_analysis_result "CRASH\n"
  mock_compiler.set_dump_file_names_result "CRASH\n$protocol1\n"

  semaphore := monitor.Semaphore

  crash_count := 0
  client.install_handler "window/showMessage"::
    message := it["message"]
    expect (message.contains "Compiler crashed")
    expect (message.contains "/tmp/")
    repro_path := message.copy (message.index_of "/tmp/")
    expect (file.is_file repro_path)
    content := file.read_content repro_path
    // We are only looking for "protocol1.toit" to avoid issues with Unicode characters.
    expect (binary_contains_string content "/protocol1.toit")
    file.delete repro_path
    crash_count++
    semaphore.up

  print "simulating crash"
  client.send_did_change --path=protocol1 "foo"

  expect_equals crash_count 1

  semaphore.down
  expect_equals crash_count 1  // Should not be necessary, but can't hurt.
