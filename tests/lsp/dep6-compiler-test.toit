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
  // The paths must not exist. We are closing one file, and are testing
  // whether the LSP can deal with it.
  DOC-COUNT ::= 2
  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  MODULE-NAME-PREFIX ::= "some_non_existing_path_1234134123422"
  relatives := List DOC-COUNT: ".$MODULE-NAME-PREFIX$it"
  paths := List DOC-COUNT: "$DRIVE/tmp/$MODULE-NAME-PREFIX$(it).toit"

  DOC-COUNT.repeat:
    client.send-did-open --path=paths[it] --text=""

  DOC-COUNT.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  client.send-did-change --path=paths[0] """
    import $relatives[1]
    main:
      unresolved
    """

  diagnostics := client.diagnostics-for --path=paths[0]
  expect-equals 1 diagnostics.size

  client.send-did-close --path=paths[0]

  // At this point the file is as if it was deleted for the LSP server.

  client.send-did-change --path=paths[1] """
    foo:  // Forcing a summary change.
    """

  3.repeat:
    client.send-did-change --path=paths[1] "foo:"
    diagnostics = client.diagnostics-for --path=paths[1]
    expect-equals 0 diagnostics.size

    client.send-did-change --path=paths[1] "foo: unresolved"
    diagnostics = client.diagnostics-for --path=paths[1]
    expect-equals 1 diagnostics.size
