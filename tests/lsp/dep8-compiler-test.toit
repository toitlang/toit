// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import system
import system show platform

main args:
  run-client-test args: test it

// Some types are implicitly exported, as they are the return type of functions.
// Make sure that changes to that type propagate through all reverse dependencies.
test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.
  LEVELS ::= 4
  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  DIR ::= "$DRIVE/non_existing_dir_toit_test"
  MODULE-NAME-PREFIX ::= "some_non_existing_path"
  relatives := List LEVELS: ".$MODULE-NAME-PREFIX$it"
  paths := List LEVELS: "$DIR/$MODULE-NAME-PREFIX$(it).toit"

  PATH1-CODE ::= """
    import $relatives[1]
    main:
      foo.bar.gee
    """

  PATH2-CODE ::= """
    import $relatives[2]

    foo -> A: return A
    """

  PATH3-CODE ::= """
    import $relatives[3]
    class A:
      bar -> B: return B
    """

  PATH4-CODE-GEE-THUNK ::= """
    class B:
      gee: return 0
    """

  PATH4-CODE-GEE-1ARG ::= """
    class B:
      gee x: return 0
    """

  LEVELS.repeat:
    client.send-did-open --path=paths[it] --text=""

  LEVELS.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  client.send-did-change --path=paths[0] PATH1-CODE
  client.send-did-change --path=paths[1] PATH2-CODE
  client.send-did-change --path=paths[2] PATH3-CODE
  client.send-did-change --path=paths[3] PATH4-CODE-GEE-THUNK

  LEVELS.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  client.clear-diagnostics

  client.send-did-change --path=paths[3] PATH4-CODE-GEE-1ARG

  LEVELS.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    if it == 0:
      // Missing argument to gee.
      expect-equals 1 diagnostics.size
    else:
      expect-equals 0 diagnostics.size
