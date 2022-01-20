// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.
  LEVELS ::= 2
  MODULE_NAME_PREFIX ::= "some_non_existing_path"
  relatives := List LEVELS: ".$MODULE_NAME_PREFIX$it"
  paths := List LEVELS: "/tmp/$MODULE_NAME_PREFIX$(it).toit"

  PATH1_CODE ::= """
    import $relatives[1]
    main:
      foo.bar
    """

  PATH2_CODE ::= """
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

  PATH2_CODE_DIFFERENT_LOCATIONS ::= "// Additional first line\n" + PATH2_CODE

  LEVELS.repeat:
    client.send_did_open --path=paths[it] --text=""

  LEVELS.repeat:
    diagnostics := client.diagnostics_for --path=paths[it]
    expect_equals 0 diagnostics.size

  client.send_did_change --path=paths[0] PATH1_CODE
  client.send_did_change --path=paths[1] PATH2_CODE

  diagnostics := client.diagnostics_for --path=paths[0]
  expect_equals 1 diagnostics.size  // 'A doesn't have a `foo` method.
  diagnostics = client.diagnostics_for --path=paths[1]
  diagnostics.do: print it
  expect_equals 0 diagnostics.size

  client.clear_diagnostics

  client.send_did_change --path=paths[1] PATH2_CODE_DIFFERENT_LOCATIONS
  // Since the summary hasn't changed (except in locations), we don't get new diagnostics for path[0].
  expect_null (client.diagnostics_for --path=paths[0])
