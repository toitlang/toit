// Copyright (C) 2019 Toitware ApS. All rights reserved.

import host.directory
import .lsp_client show LspClient run_client_test
import expect show *
import host.file

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  underscore_path := "$(directory.cwd)/under_score.toit"
  escaped_uri := client.to_uri underscore_path

  // The internal URI translator is expected to translate "_" to "%5f".
  // That's not required. If it changes, then the test should be rewritten.
  // We want to provide a URI that isn't the one that the LSP server uses
  // internally.
  // So here the LSP server uses "%5f" and we will use "_".
  expect (escaped_uri.contains "%5f")
  uri := escaped_uri.replace --all "%5f" "_"

  print "Checking that the file has errors."
  underscore_content := (file.read_content underscore_path).to_string
  client.send_did_open --uri=uri --text=underscore_content
  // By finding the diagnostics for the escaped_uri, we know that the server
  // replaced the "%5f"
  diagnostics := client.diagnostics_for --uri=escaped_uri
  expect_equals 1 diagnostics.size

  print "Get goto-definition with underscore"
  response := client.send_goto_definition_request --uri=uri 5 20
  expect_equals 1 response.size
  definition := response.first
  expect_equals escaped_uri definition["uri"]
