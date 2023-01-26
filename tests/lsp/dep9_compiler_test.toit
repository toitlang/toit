// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

// Some types are implicitly exported, as they are the return type of functions.
// Make sure that changes to that type propagate through all reverse dependencies.
test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.
  LEVELS ::= 3
  DRIVE ::= platform == PLATFORM_WINDOWS ? "c:" : ""
  DIR ::= "$DRIVE/non_existing_dir_toit_test"
  MODULE_NAME_PREFIX ::= "some_non_existing_path"
  relatives := List LEVELS: ".$MODULE_NAME_PREFIX$it"
  paths := List LEVELS: "$DIR/$MODULE_NAME_PREFIX$(it).toit"

  PATH1_CODE ::= """
    import $relatives[1]
    main:
      foo
    """

  PATH2_CODE ::= """
    import $relatives[2] as pre
    export *  // Doesn't export anything.
    """

  PATH2_CODE_NO_PREFIX ::= """
    import $relatives[2]
    export *  // Exports everything from $relatives[2]
    """

  PATH3_CODE ::= """
    foo:
    """

  LEVELS.repeat:
    client.send_did_open --path=paths[it] --text=""

  LEVELS.repeat:
    diagnostics := client.diagnostics_for --path=paths[it]
    expect_equals 0 diagnostics.size

  client.send_did_change --path=paths[0] PATH1_CODE
  client.send_did_change --path=paths[1] PATH2_CODE
  client.send_did_change --path=paths[2] PATH3_CODE

  LEVELS.repeat:
    diagnostics := client.diagnostics_for --path=paths[it]
    if it == 0:
      // Unresolved 'foo'.
      expect_equals 1 diagnostics.size
    else:
      expect_equals 0 diagnostics.size

  client.send_did_change --path=paths[1] PATH2_CODE_NO_PREFIX

  LEVELS.repeat:
    diagnostics := client.diagnostics_for --path=paths[it]
    expect_equals 0 diagnostics.size
