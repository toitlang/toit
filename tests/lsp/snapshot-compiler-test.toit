// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *
import host.file
import encoding.base64 as base64
import .utils

HELLO-WORLD ::= """
  main: print "hello world"
  """

check-snapshot toitc path:
  lines := run-toit toitc [path]
  expect-equals 1 lines.size
  expect-equals "hello world" lines.first

test client/LspClient toitc:
  uri := "untitled:Untitled0"
  client.send-did-open --uri=uri --text=HELLO-WORLD

  snapshot-bundle := client.send-request "toit/snapshotBundle" { "uri": uri }
  expect-not-null snapshot-bundle

  dir := directory.mkdtemp "/tmp/test-lsp-snapshot-"
  snapshot-path := "$dir/hello.snapshot"
  try:
    writer := file.Stream.for-write snapshot-path
    writer.out.write (base64.decode snapshot-bundle["snapshot_bundle"])
    writer.close

    check-snapshot toitc snapshot-path

  finally:
    directory.rmdir --recursive dir

main args:
  run-client-test args: test it args[0]
