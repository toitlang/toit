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
  LEVELS ::= 3
  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  MODULE-NAME-PREFIX ::= "some_non_existing_path"
  relatives := List LEVELS: ".$MODULE-NAME-PREFIX$it"
  paths := List LEVELS: "$DRIVE/tmp/$MODULE-NAME-PREFIX$(it).toit"

  LEVELS.repeat:
    client.send-did-open --path=paths[it] --text=""

  LEVELS.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  client.send-did-change --path=paths[0] """
    import $relatives[1]
    main:
      foo.bar
    """

  client.send-did-change --path=paths[1] """
    import $relatives[2]
    foo -> A:
      return A
    """

  diagnostics := client.diagnostics-for --path=paths[0]
  // At this point there isn't any error, since 'A' is not known, and the call to `bar` not checked.
  expect-equals 0 diagnostics.size
  diagnostics = client.diagnostics-for --path=paths[1]
  expect diagnostics.size > 0  // 'A' is unresolved.

  client.send-did-change --path=paths[2] """
    class A:
      gee:  // No method 'foo'
    """

  diagnostics = client.diagnostics-for --path=paths[2]
  expect-equals 0 diagnostics.size
  diagnostics = client.diagnostics-for --path=paths[1]
  expect-equals 0 diagnostics.size
  diagnostics = client.diagnostics-for --path=paths[0]
  // Now there is a warning, since `bar` is not a method in `A`.
  // expect_equals 1 diagnostics.size


  client.send-did-change --path=paths[0] """
    import $relatives[1]
    class A:
    foo -> A: return A
    main:
      fooX.bar
    """
