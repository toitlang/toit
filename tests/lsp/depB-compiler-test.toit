// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import system
import system show platform

main args:
  run-client-test args: test it
  run-client-test --use-toitlsp args: test it

// Make sure that deprecation is correctly handled.
test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.

  DRIVE ::= platform == system.PLATFORM-WINDOWS ? "c:" : ""
  DIR ::= "$DRIVE/non_existing_dir_toit_test"
  MODULE-NAME-PREFIX ::= "some_non_existing_path"
  RELATIVE2 ::= ".$(MODULE-NAME-PREFIX)2"
  PATH1 ::= "$DIR/$(MODULE-NAME-PREFIX)1.toit"
  PATH2 ::= "$DIR/$(MODULE-NAME-PREFIX)2.toit"

  PATH1-CODE ::= """
    import $RELATIVE2 as other

    main:
      a := other.A
      bar := a.bar
      foo := other.foo 1 2
      gee := other.global
    """

  PATH2-CODE-NO-ERROR ::= """
    class A:
      bar := 42

    foo x y:
      return x + y

    global ::= 499
    """

  PATH2-DEPRECATED-CODES ::= [
    """
    /// Deprecated.
    class A:
      bar := 42

    foo x y:
      return x + y

    global ::= 499
    """,

    """
    /// Deprecated.
    class A:
      /// Deprecated.
      bar := 42

    foo x y:
      return x + y

    global ::= 499
    """,

    """
    /// Deprecated.
    class A:
      /// Deprecated.
      bar := 42

    /// Deprecated.
    foo x y:
      return x + y

    global ::= 499
    """,

    """
    /// Deprecated.
    class A:
      /// Deprecated.
      bar := 42

    /// Deprecated.
    foo x y:
      return x + y

    /// Deprecated.
    global ::= 499
    """,
  ]

  client.send-did-open --path=PATH2 --text=PATH2-CODE-NO-ERROR
  client.send-did-open --path=PATH1 --text=PATH1-CODE

  [PATH1, PATH2].do:
    diagnostics := client.diagnostics-for --path=it
    diagnostics.do: print it
    expect-equals 0 diagnostics.size

  expected-warnings := 0
  PATH2-DEPRECATED-CODES.do: | deprecated-code |
    expected-warnings++
    // A deprecation-warning change in a dependency triggers a re-analysis of the
    // dependent file.
    client.send-did-change --path=PATH2 deprecated-code
    diagnostics := client.diagnostics-for --path=PATH1
    expect-equals expected-warnings diagnostics.size
