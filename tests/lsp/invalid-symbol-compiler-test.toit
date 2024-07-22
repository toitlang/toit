// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *
import system
import system show platform

main args:
  run-client-test args: test it

test client/LspClient:
  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  path := "$DRIVE/not_important_non_existing.toit"
  client.send-did-open --path=path --text=""

  print "Invalid class name"
  client.send-did-change --path=path "class"
  diagnostics := client.diagnostics-for --path=path
  expect-equals 1 diagnostics.size

  print "Invalid method name"
  client.send-did-change --path=path """
    abstract class A:
      abstract"""
  diagnostics = client.diagnostics-for --path=path
  expect-equals 1 diagnostics.size
