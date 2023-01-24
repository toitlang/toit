// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

PATH0_CODE ::= """
  // Modules that use monitors.
  import monitor
  import at
  import coap

  main:
  """

PATH1_CODE ::= """
  // Modules that use monitors.
  // In reverse order.
  import coap
  import at
  import monitor

  main:
  """

PATH0_ERROR_CODE ::= """
  // Modules that use monitors.
  import monitor
  import at
  import coap

  main:
    unresolved
  """

test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.
  DOC_COUNT ::= 2
  DRIVE ::= platform == PLATFORM_WINDOWS ? "c:" : ""
  MODULE_NAME_PREFIX ::= "some_non_existing_path"
  relatives := List DOC_COUNT: ".$MODULE_NAME_PREFIX$it"
  paths := List DOC_COUNT: "$DRIVE/tmp/$MODULE_NAME_PREFIX$(it).toit"

  DOC_COUNT.repeat:
    client.send_did_open --path=paths[it] --text=""

  DOC_COUNT.repeat:
    diagnostics := client.diagnostics_for --path=paths[it]
    expect_equals 0 diagnostics.size

  client.send_did_change --path=paths[0] PATH0_CODE
  client.send_did_change --path=paths[1] PATH1_CODE

  DOC_COUNT.repeat:
    diagnostics := client.diagnostics_for --path=paths[it]
    expect_equals 0 diagnostics.size

  5.repeat:
    client.send_did_change --path=paths[0] PATH0_CODE
    diagnostics := client.diagnostics_for --path=paths[0]
    expect_equals 0 diagnostics.size

    client.send_did_change --path=paths[0] PATH0_ERROR_CODE
    diagnostics = client.diagnostics_for --path=paths[0]
    expect_equals 1 diagnostics.size
