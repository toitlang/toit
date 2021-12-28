// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  // The paths must not exist. We are closing one file, and are testing
  // whether the LSP can deal with it.
  DOC_COUNT ::= 2
  MODULE_NAME_PREFIX ::= "some_non_existing_path_1234134123422"
  relatives := List DOC_COUNT: ".$MODULE_NAME_PREFIX$it"
  paths := List DOC_COUNT: "/tmp/$MODULE_NAME_PREFIX$(it).toit"

  DOC_COUNT.repeat:
    client.send_did_open --path=paths[it] --text=""

  DOC_COUNT.repeat:
    diagnostics := client.diagnostics_for --path=paths[it]
    expect_equals 0 diagnostics.size

  client.send_did_change --path=paths[0] """
    import $relatives[1]
    main:
      unresolved
    """

  diagnostics := client.diagnostics_for --path=paths[0]
  expect_equals 1 diagnostics.size

  client.send_did_close --path=paths[0]

  // At this point the file is as if it was deleted for the LSP server.

  client.send_did_change --path=paths[1] """
    foo:  // Forcing a summary change.
    """

  3.repeat:
    client.send_did_change --path=paths[1] "foo:"
    diagnostics = client.diagnostics_for --path=paths[1]
    expect_equals 0 diagnostics.size

    client.send_did_change --path=paths[1] "foo: unresolved"
    diagnostics = client.diagnostics_for --path=paths[1]
    expect_equals 1 diagnostics.size
