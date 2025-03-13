// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import .lsp-client show LspClient run-client-test
import expect show *
import host.file
import system
import system show platform

main args:
  run_client_test args: test it

test client/LspClient:
  space-foo := "$(directory.cwd)/with space/foo.toit"
  space-bar := "$(directory.cwd)/with space/bar.toit"

  if platform == system.PLATFORM-WINDOWS:
    space-foo = space-foo.replace --all "/" "\\"
    space-bar = space-bar.replace --all "/" "\\"

  print "Checking that foo has one error."
  foo-content := (file.read-contents space-foo).to-string
  client.send-did-open --path=space-foo --text=foo-content
  uri := client.to-uri space-foo
  expect (uri.contains "%20")
  diagnostics := client.diagnostics-for --uri=uri
  expect-equals 1 diagnostics.size
  diagnostic := diagnostics[0]
  expect-equals 7 diagnostic["range"]["start"]["line"]
  expect-equals 2 diagnostic["range"]["start"]["character"]

  print "Get goto-definition with space"
  response := client.send-goto-definition-request --path=space-foo 7 3
  expect-equals 1 response.size
  definition := response.first
  expect-equals space-bar (client.to-path definition["uri"])
  expect (definition["uri"].contains "%20")
