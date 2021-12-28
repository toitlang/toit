// Copyright (C) 2020 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import host.directory
import host.file
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  path := "$(directory.cwd)/null_char.toit"
  client.send_did_open --path=path
  diagnostics := client.diagnostics_for --path=path
  expect_equals 4 diagnostics.size

  content := (file.read_content path).to_string
  untitled_uri := "untitled:Untitled-1"
  client.send_did_open --uri=untitled_uri --text=content
  diagnostics = client.diagnostics_for --path=path
  expect_equals 4 diagnostics.size
