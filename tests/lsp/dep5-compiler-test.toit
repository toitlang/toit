// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import system
import system show platform

main args:
  run-client-test args: test it

PATH0-CODE ::= """
  // Modules that use monitors.
  import monitor
  import zlib
  import coap

  main:
  """

PATH1-CODE ::= """
  // Modules that use monitors.
  // In reverse order.
  import coap
  import zlib
  import monitor

  main:
  """

PATH0-ERROR-CODE ::= """
  // Modules that use monitors.
  import monitor
  import zlib
  import coap

  main:
    unresolved
  """

test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.
  DOC-COUNT ::= 2
  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  MODULE-NAME-PREFIX ::= "some_non_existing_path"
  relatives := List DOC-COUNT: ".$MODULE-NAME-PREFIX$it"
  paths := List DOC-COUNT: "$DRIVE/tmp/$MODULE-NAME-PREFIX$(it).toit"

  DOC-COUNT.repeat:
    client.send-did-open --path=paths[it] --text=""

  DOC-COUNT.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  client.send-did-change --path=paths[0] PATH0-CODE
  client.send-did-change --path=paths[1] PATH1-CODE

  DOC-COUNT.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  5.repeat:
    client.send-did-change --path=paths[0] PATH0-CODE
    diagnostics := client.diagnostics-for --path=paths[0]
    expect-equals 0 diagnostics.size

    client.send-did-change --path=paths[0] PATH0-ERROR-CODE
    diagnostics = client.diagnostics-for --path=paths[0]
    expect-equals 1 diagnostics.size
