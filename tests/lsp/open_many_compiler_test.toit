// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *
import host.file
import monitor

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  protocol1 := "$(directory.cwd)/protocol1.toit"
  protocol2 := "$(directory.cwd)/protocol2.toit"
  protocol3 := "$(directory.cwd)/protocol3.toit"
  files_to_open_and_diagnostics := [
    [protocol1, 0],
    [protocol2, 1],
    [protocol3, 0],
  ]
  files_to_open := files_to_open_and_diagnostics.map: it[0]

  client.send_did_open_many --paths=files_to_open
  files_to_open_and_diagnostics.do:
    file := it[0]
    expected_diagnostics := it[1]
    diagnostics := client.diagnostics_for --path=file
    expect_equals expected_diagnostics diagnostics.size
