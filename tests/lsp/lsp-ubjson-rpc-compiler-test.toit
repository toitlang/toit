// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *
import host.file
import monitor

DRIVE ::= platform == PLATFORM-WINDOWS ? "c:" : ""
PATH-PREFIX ::= "$DRIVE/non_existent/some path with spaces and :/toit_test"

PATH1 ::= "$PATH-PREFIX/p1.toit"
PATH2 ::= "$PATH-PREFIX/p2.toit"
PATH3 ::= "$PATH-PREFIX/p3.toit"

main args:
  // Testing using json.
  run-client-test
      args
      --pre-initialize=: | _ init-params |
        init-params["capabilities"]["experimental"]["ubjsonRpc"] = false:
    test it

  // Testing unexpected ubjson messages.
  run-client-test
      args
      --pre-initialize=: | client init-params |
        init-params["capabilities"]["experimental"]["ubjsonRpc"] = false
        client.connection_.enable-ubjson:
    test it

  // Testing two-way ubjson messages.
  run-client-test
      args
      --pre-initialize=:
        it.connection_.enable-ubjson:
    test it --uses-ubjson

test client/LspClient --uses-ubjson=false:
  path := "$PATH-PREFIX/f1.toit"
  client.send-did-open --path=path --text="main:"
  diagnostics := client.diagnostics-for --path=path
  expect-equals 0 diagnostics.size

  path = "$PATH-PREFIX/f2.toit"
  client.send-did-open --path=path --text="main: foo"
  diagnostics = client.diagnostics-for --path=path
  expect-equals 1 diagnostics.size

  path = "$PATH-PREFIX/f3.toit"
  client.send-did-open --path=path --text="main:\n  foo\n  bar"
  diagnostics = client.diagnostics-for --path=path
  expect-equals 2 diagnostics.size

  if uses-ubjson:
    expect client.connection_.ubjson-count_ > 0
    expect client.connection_.json-count_ == 0
  else:
    expect client.connection_.ubjson-count_ == 0
    expect client.connection_.json-count_ > 0
