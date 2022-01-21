// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *

main args:
  run_client_test args
      --pre_initialize=: it.configuration["timeoutMs"] = 0:
    test it
  run_client_test args
      --use_toitlsp
      --pre_initialize=: it.configuration["timeoutMs"] = 0:
    test it

LINES ::= 10000

test client/LspClient:
  print "Building big file with $LINES lines."
  big_string_chunks := [
    "main:"
  ]
  LINES.repeat:
    big_string_chunks.add "  unresolved"
  big_string := big_string_chunks.join "\n"
  print "Big file built."
  print "Notifying server of new file."
  uri := "untitled:/non_existent.toit"
  client.send_did_open --uri=uri --text=big_string
  print "Checking that we got lots of errors."
  diagnostics := client.diagnostics_for --uri=uri
  expect_equals LINES diagnostics.size
