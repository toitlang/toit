// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  DRIVE ::= platform == PLATFORM_WINDOWS ? "c:" : ""
  path := "$DRIVE/not_important_non_existing.toit"
  client.send_did_open --path=path --text=""

  print "Invalid class name"
  client.send_did_change --path=path "class"
  diagnostics := client.diagnostics_for --path=path
  expect_equals 1 diagnostics.size

  print "Invalid method name"
  client.send_did_change --path=path """
    abstract class A:
      abstract"""
  diagnostics = client.diagnostics_for --path=path
  expect_equals 1 diagnostics.size
