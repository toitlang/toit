// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

// Make sure that the `abstract` keyword is correctly handled.
test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.

  DRIVE ::= platform == PLATFORM_WINDOWS ? "c:" : ""
  DIR ::= "$DRIVE/non_existing_dir_toit_test"
  MODULE_NAME_PREFIX ::= "some_non_existing_path"
  RELATIVE2 ::= ".$(MODULE_NAME_PREFIX)2"
  PATH1 ::= "$DIR/$(MODULE_NAME_PREFIX)1.toit"
  PATH2 ::= "$DIR/$(MODULE_NAME_PREFIX)2.toit"

  PATH1_CODE ::= """
    import $RELATIVE2

    class B extends A:

    main:
      (B).foo
      (C).foo
    """

  PATH2_CODE_NO_ERROR ::= """
    abstract class A:
      foo:

    class C:
      foo:
    """

  PATH2_CODE_MISSING_FOO ::= """
    abstract class A:
      abstract foo

    class C:
      foo:
    """

  PATH2_CODE_ABSTRACT_C ::= """
    abstract class A:
      foo:

    abstract class C:
      foo:
    """

  client.send_did_open --path=PATH2 --text=PATH2_CODE_NO_ERROR
  client.send_did_open --path=PATH1 --text=PATH1_CODE

  [PATH1, PATH2].do:
    diagnostics := client.diagnostics_for --path=it
    diagnostics.do: print it
    expect_equals 0 diagnostics.size

  client.send_did_change --path=PATH2 PATH2_CODE_MISSING_FOO
  diagnostics := client.diagnostics_for --path=PATH1
  // We expect an error for the missing 'foo' implementation.
  expect_equals 1 diagnostics.size
  diagnostics = client.diagnostics_for --path=PATH2
  expect_equals 0 diagnostics.size

  client.send_did_change --path=PATH2 PATH2_CODE_NO_ERROR
  [PATH1, PATH2].do:
    diagnostics = client.diagnostics_for --path=it
    expect_equals 0 diagnostics.size

  client.send_did_change --path=PATH2 PATH2_CODE_ABSTRACT_C
  diagnostics = client.diagnostics_for --path=PATH1
  // We expect an error for instantiating an abstract class.
  expect_equals 1 diagnostics.size
  diagnostics = client.diagnostics_for --path=PATH2
  expect_equals 0 diagnostics.size
