// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *
import host.file
import encoding.base64 as base64
import .utils

HELLO_WORLD ::= """
  main: print "hello world"
  """

check_snapshot toitc path:
  lines := run_toit toitc [path]
  expect_equals 1 lines.size
  expect_equals "hello world" lines.first

test client/LspClient toitc:
  uri := "untitled:Untitled0"
  client.send_did_open --uri=uri --text=HELLO_WORLD

  snapshot_bundle := client.send_request "toit/snapshot_bundle" { "uri": uri }
  expect_not_null snapshot_bundle

  dir := directory.mkdtemp "/tmp/test-lsp-snapshot-"
  snapshot_path := "$dir/hello.snapshot"
  try:
    writer := file.Stream.for_write snapshot_path
    writer.write (base64.decode snapshot_bundle["snapshot_bundle"])
    writer.close

    check_snapshot toitc snapshot_path

  finally:
    directory.rmdir --recursive dir

main args:
  run_client_test args: test it args[0]
  run_client_test --use_toitlsp args: test it args[0]
