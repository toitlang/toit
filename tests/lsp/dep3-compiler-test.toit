// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import system
import system show platform

main args:
  run-client-test args: test it

test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.

  LEVELS ::= 6
  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  MODULE-NAME-PREFIX ::= "some_non_existing_path"
  relatives := List LEVELS: ".$MODULE-NAME-PREFIX$it"
  paths := List LEVELS: "$DRIVE/$MODULE-NAME-PREFIX$(it).toit"

  LEVELS.repeat:
    client.send-did-open --path=paths[it] --text=""

  // Build up a chain of import/exports.
  for i := 1; i < LEVELS - 1; i++:
    content := "import $relatives[i + 1]\nexport *"
    client.send-did-change --path=paths[i] content

  client.send-did-change --path=paths[0] """
    import $relatives[1]
    main:
      foo // Error because 'foo' is unresolved
    """
  diagnostics := client.diagnostics-for --path=paths[0]
  expect-equals 1 diagnostics.size
  for i := 1; i < LEVELS; i++:
    diagnostics = client.diagnostics-for --path=paths[i]
    expect-equals 0 diagnostics.size

  client.clear-diagnostics

  // We change the last of the paths, and expect that change
  //   to propagate (through the import/exports) to the first one.
  client.send-did-change --path=paths[LEVELS - 1] """
    foo: return 123
    """
  LEVELS.repeat:
    diagnostics = client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  // We change the last of the paths, and expect that change
  //   to propagate (through the import/exports) to the first one.
  client.send-did-change --path=paths[LEVELS - 1] """
    foo x: return 123
    """
  diagnostics = client.diagnostics-for --path=paths[0]
  expect-equals 1 diagnostics.size
  for i := 1; i < LEVELS; i++:
    diagnostics = client.diagnostics-for --path=paths[i]
    expect-equals 0 diagnostics.size
