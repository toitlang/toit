// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.

  LEVELS ::= 6
  DRIVE ::= platform == PLATFORM_WINDOWS ? "c:" : ""
  MODULE_NAME_PREFIX ::= "some_non_existing_path"
  relatives := List LEVELS: ".$MODULE_NAME_PREFIX$it"
  paths := List LEVELS: "$DRIVE/$MODULE_NAME_PREFIX$(it).toit"

  LEVELS.repeat:
    client.send_did_open --path=paths[it] --text=""

  // Build up a chain of import/exports.
  for i := 1; i < LEVELS - 1; i++:
    content := "import $relatives[i + 1]\nexport *"
    client.send_did_change --path=paths[i] content

  client.send_did_change --path=paths[0] """
    import $relatives[1]
    main:
      foo // Error because 'foo' is unresolved
    """
  diagnostics := client.diagnostics_for --path=paths[0]
  expect_equals 1 diagnostics.size
  for i := 1; i < LEVELS; i++:
    diagnostics = client.diagnostics_for --path=paths[i]
    expect_equals 0 diagnostics.size

  client.clear_diagnostics

  // We change the last of the paths, and expect that change
  //   to propagate (through the import/exports) to the first one.
  client.send_did_change --path=paths[LEVELS - 1] """
    foo: return 123
    """
  LEVELS.repeat:
    diagnostics = client.diagnostics_for --path=paths[it]
    expect_equals 0 diagnostics.size

  // We change the last of the paths, and expect that change
  //   to propagate (through the import/exports) to the first one.
  client.send_did_change --path=paths[LEVELS - 1] """
    foo x: return 123
    """
  diagnostics = client.diagnostics_for --path=paths[0]
  expect_equals 1 diagnostics.size
  for i := 1; i < LEVELS; i++:
    diagnostics = client.diagnostics_for --path=paths[i]
    expect_equals 0 diagnostics.size
