// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  warning_path := "$(directory.cwd)/warning.toit"
  client.send_did_open --path=warning_path
  diagnostics := client.diagnostics_for --path=warning_path
  expect_equals 1 diagnostics.size
