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
  LEVELS ::= 2
  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  MODULE-NAME-PREFIX ::= "some_non_existing_path"
  relatives := List LEVELS: ".$MODULE-NAME-PREFIX$it"
  paths := List LEVELS: "$DRIVE/tmp/$MODULE-NAME-PREFIX$(it).toit"

  PATH1-CODE ::= """
    import $relatives[1]
    main:
      foo.bar
    """

  PATH2-CODE ::= """
    import core show List
    export *

    abstract class A:
      field := 0
      some_method: null
      static some_static_method: 42
      abstract some_abstract
      constructor:
      constructor.named_constructor:
      constructor.factory: return B

    class B extends A:
      some_abstract: 499

    a_global ::= 42

    foo -> B:
      return B
    """

  PATH2-CODE-DIFFERENT-LOCATIONS ::= "// Additional first line\n" + PATH2-CODE

  LEVELS.repeat:
    client.send-did-open --path=paths[it] --text=""

  LEVELS.repeat:
    diagnostics := client.diagnostics-for --path=paths[it]
    expect-equals 0 diagnostics.size

  client.send-did-change --path=paths[0] PATH1-CODE
  client.send-did-change --path=paths[1] PATH2-CODE

  diagnostics := client.diagnostics-for --path=paths[0]
  expect-equals 1 diagnostics.size  // 'A doesn't have a `foo` method.
  diagnostics = client.diagnostics-for --path=paths[1]
  diagnostics.do: print it
  expect-equals 0 diagnostics.size

  client.clear-diagnostics

  client.send-did-change --path=paths[1] PATH2-CODE-DIFFERENT-LOCATIONS
  // Since the summary hasn't changed (except in locations), we don't get new diagnostics for path[0].
  expect-null (client.diagnostics-for --path=paths[0])
