// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  // The path doesn't really need to be non-existing, as we provide content for it
  // anyways.
  DIR ::= "/non_existing_dir_toit_test"
  path := "/non_exsting_dir_toit_test/file.toit"

  client.send_did_open --path=path --text=""

  client.send_did_change --path=path "// "
  // A completion at the end of the file.
  suggestions := client.send_completion_request --path=path 0 3
  expect suggestions.is_empty

  client.send_did_change --path=path "/* "
  // A completion at the end of the file.
  suggestions = client.send_completion_request --path=path 0 3
  expect suggestions.is_empty

  client.send_did_change --path=path "\"  "
  // A completion at the end of the file.
  suggestions = client.send_completion_request --path=path 0 3
  expect suggestions.is_empty

  client.send_did_change --path=path "f: \nbar:"
  // A completion at the end of the file.
  suggestions = client.send_completion_request --path=path 0 3
  expect (suggestions.any: it["label"] == "bar")
