// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import system
import system show platform

main args:
  run-client-test args: test it

// Make sure that the `abstract` keyword is correctly handled.
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
    import $RELATIVE2

    class B extends A:

    main:
      (B).foo
      (C).foo
    """

  PATH2-CODE-NO-ERROR ::= """
    abstract class A:
      foo:

    class C:
      foo:
    """

  PATH2-CODE-MISSING-FOO ::= """
    abstract class A:
      abstract foo

    class C:
      foo:
    """

  PATH2-CODE-ABSTRACT-C ::= """
    abstract class A:
      foo:

    abstract class C:
      foo:
    """

  client.send-did-open --path=PATH2 --text=PATH2-CODE-NO-ERROR
  client.send-did-open --path=PATH1 --text=PATH1-CODE

  [PATH1, PATH2].do:
    diagnostics := client.diagnostics-for --path=it
    diagnostics.do: print it
    expect-equals 0 diagnostics.size

  client.send-did-change --path=PATH2 PATH2-CODE-MISSING-FOO
  diagnostics := client.diagnostics-for --path=PATH1
  // We expect an error for the missing 'foo' implementation.
  expect-equals 1 diagnostics.size
  diagnostics = client.diagnostics-for --path=PATH2
  expect-equals 0 diagnostics.size

  client.send-did-change --path=PATH2 PATH2-CODE-NO-ERROR
  [PATH1, PATH2].do:
    diagnostics = client.diagnostics-for --path=it
    expect-equals 0 diagnostics.size

  client.send-did-change --path=PATH2 PATH2-CODE-ABSTRACT-C
  diagnostics = client.diagnostics-for --path=PATH1
  // We expect an error for instantiating an abstract class.
  expect-equals 1 diagnostics.size
  diagnostics = client.diagnostics-for --path=PATH2
  expect-equals 0 diagnostics.size
