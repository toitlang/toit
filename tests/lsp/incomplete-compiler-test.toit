// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import system
import system show platform

main args:
  run-client-test args: test it

test client/LspClient:
  // The path doesn't really need to be non-existing, as we provide content for it
  // anyways.
  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  DIR ::= "$DRIVE/non_existing_dir_toit_test"
  path := "$DIR/file.toit"

  client.send-did-open --path=path --text=""

  client.send-did-change --path=path "// "
  // A completion at the end of the file.
  suggestions := client.send-completion-request --path=path 0 3
  expect suggestions.is-empty

  client.send-did-change --path=path "/* "
  // A completion at the end of the file.
  suggestions = client.send-completion-request --path=path 0 3
  expect suggestions.is-empty

  client.send-did-change --path=path "\"  "
  // A completion at the end of the file.
  suggestions = client.send-completion-request --path=path 0 3
  expect suggestions.is-empty

  client.send-did-change --path=path "f: \nbar:"
  // A completion at the end of the file.
  suggestions = client.send-completion-request --path=path 0 3
  expect (suggestions.any: it["label"] == "bar")
