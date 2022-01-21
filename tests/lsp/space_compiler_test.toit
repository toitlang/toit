// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import .lsp_client show LspClient run_client_test
import expect show *
import host.file

main args:
  run_client_test --use_toitlsp args: test it
 // run_client_test args: test it

test client/LspClient:
  space_foo := "$(directory.cwd)/with space/foo.toit"
  space_bar := "$(directory.cwd)/with space/bar.toit"

  print "Checking that foo has one error."
  foo_content := (file.read_content space_foo).to_string
  client.send_did_open --path=space_foo --text=foo_content
  uri := client.to_uri space_foo
  expect (uri.contains "%20")
  diagnostics := client.diagnostics_for --uri=uri
  expect_equals 1 diagnostics.size
  diagnostic := diagnostics[0]
  expect_equals 7 diagnostic["range"]["start"]["line"]
  expect_equals 2 diagnostic["range"]["start"]["character"]

  print "Get goto-definition with space"
  response := client.send_goto_definition_request --path=space_foo 7 3
  expect_equals 1 response.size
  definition := response.first
  expect_equals space_bar (client.to_path definition["uri"])
  expect (definition["uri"].contains "%20")
