// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *
import host.file
import monitor

PATH_PREFIX ::= "/non_existent/some path with spaces and :/toit_test"

PATH1 ::= "$PATH_PREFIX/p1.toit"
PATH2 ::= "$PATH_PREFIX/p2.toit"
PATH3 ::= "$PATH_PREFIX/p3.toit"

main args:
  // Testing using json.
  run_client_test
      args
      --pre_initialize=: | _ init_params |
        init_params["capabilities"]["experimental"]["ubjsonRpc"] = false:
    test it

  // Testing unexpected ubjson messages.
  run_client_test
      args
      --pre_initialize=: | client init_params |
        init_params["capabilities"]["experimental"]["ubjsonRpc"] = false
        client.connection_.enable_ubjson:
    test it

  // Testing two-way ubjson messages.
  run_client_test
      args
      --pre_initialize=:
        it.connection_.enable_ubjson:
    test it --uses_ubjson

test client/LspClient --uses_ubjson=false:
  path := "$PATH_PREFIX/f1.toit"
  client.send_did_open --path=path --text="main:"
  diagnostics := client.diagnostics_for --path=path
  expect_equals 0 diagnostics.size

  path = "$PATH_PREFIX/f2.toit"
  client.send_did_open --path=path --text="main: foo"
  diagnostics = client.diagnostics_for --path=path
  expect_equals 1 diagnostics.size

  path = "$PATH_PREFIX/f3.toit"
  client.send_did_open --path=path --text="main:\n  foo\n  bar"
  diagnostics = client.diagnostics_for --path=path
  expect_equals 2 diagnostics.size

  if uses_ubjson:
    expect client.connection_.ubjson_count_ > 0
    expect client.connection_.json_count_ == 0
  else:
    expect client.connection_.ubjson_count_ == 0
    expect client.connection_.json_count_ > 0
