// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import .lsp-client show LspClient run-client-test
import expect show *
import host.file

main args:
  run-client-test args: test it

test client/LspClient:
  underscore-path := "$(directory.cwd)/under_score.toit"
  escaped-uri := client.to-uri underscore-path

  // The internal URI translator is expected to translate "_" to "%5f".
  // That's not required. If it changes, then the test should be rewritten.
  // We want to provide a URI that isn't the one that the LSP server uses
  // internally.
  // So here the LSP server uses "%5f" and we will use "_".
  expect (escaped-uri.contains "%5f")
  uri := escaped-uri.replace --all "%5f" "_"

  print "Checking that the file has errors."
  underscore-content := (file.read-contents underscore-path).to-string
  client.send-did-open --uri=uri --text=underscore-content
  // By finding the diagnostics for the escaped_uri, we know that the server
  // replaced the "%5f"
  diagnostics := client.diagnostics-for --uri=escaped-uri
  expect-equals 1 diagnostics.size

  print "Get goto-definition with underscore"
  response := client.send-goto-definition-request --uri=uri 7 20
  expect-equals 1 response.size
  definition := response.first
  expect-equals escaped-uri definition["uri"]
