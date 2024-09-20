// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *

main args:
  run-client-test args
      --pre-initialize=: it.configuration["timeoutMs"] = 0:
    test it

LINES ::= 10000

test client/LspClient:
  print "Building big file with $LINES lines."
  big-string-chunks := [
    "main:"
  ]
  LINES.repeat:
    big-string-chunks.add "  unresolved"
  big-string := big-string-chunks.join "\n"
  print "Big file built."
  print "Notifying server of new file."
  uri := "untitled:/non_existent.toit"
  client.send-did-open --uri=uri --text=big-string
  print "Checking that we got lots of errors."
  diagnostics := client.diagnostics-for --uri=uri
  expect-equals LINES diagnostics.size
