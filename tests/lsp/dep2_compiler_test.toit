// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  // The paths don't really need to be non-existing, as we provide content for it
  // anyways.
  relative_module1 := "some_non_existing_path1"
  relative_module2 := "some_non_existing_path2"
  path1 := "/tmp/$(relative_module1).toit"
  path2 := "/tmp/$(relative_module2).toit"

  client.send_did_open --path=path1 --text=""
  client.send_did_open --path=path2 --text=""

  diagnostics := client.diagnostics_for --path=path1
  expect_equals 0 diagnostics.size
  diagnostics = client.diagnostics_for --path=path2
  expect_equals 0 diagnostics.size

  client.send_did_change --path=path1 """
    main:
      foo // Error because 'foo' is unresolved
    """
  diagnostics = client.diagnostics_for --path=path1
  expect_equals 1 diagnostics.size
  diagnostics = client.diagnostics_for --path=path2
  expect_equals 0 diagnostics.size

  client.send_did_change --path=path1 """
    import .$relative_module2
    main:
      foo
    """

  client.send_did_change --path=path2 """
    foo: return 134
    """

  diagnostics = client.diagnostics_for --path=path1
  expect_equals 0 diagnostics.size
  diagnostics = client.diagnostics_for --path=path2
  expect_equals 0 diagnostics.size

  client.send_did_change --path=path1 """
    import .$relative_module2
    main:
      foo 1  // Error because arguments don't match.
    """
  diagnostics = client.diagnostics_for --path=path1
  expect_equals 1 diagnostics.size

  client.clear_diagnostics

  diagnostics = client.diagnostics_for --path=path1
  expect_null diagnostics
  diagnostics = client.diagnostics_for --path=path2
  expect_null diagnostics

  client.send_did_change --path=path2 """
    foo: return 499  // <=== Changed number here.
    """

  // The summary of path2 didn't change, and therefore there aren't any diagnostics for path1 again.
  diagnostics = client.diagnostics_for --path=path1
  expect_null diagnostics
  diagnostics = client.diagnostics_for --path=path2
  expect_equals 0 diagnostics.size

  client.send_did_change --path=path2 """
    foo: return 499
    bar: return 42   // <=== New function
    """

  // The summary of path2 changed, and therefore there are diagnostics for path1 again.
  diagnostics = client.diagnostics_for --path=path1
  expect_equals 1 diagnostics.size
  diagnostics = client.diagnostics_for --path=path2
  expect_equals 0 diagnostics.size

  client.clear_diagnostics

  client.send_did_change --path=path2 """
    foo x: return 499  // <=== Adds parameter
    bar: return 42
    """

  // The summary of path2 changed, and therefore there are diagnostics for path1 again.
  diagnostics = client.diagnostics_for --path=path1
  expect_equals 0 diagnostics.size
  diagnostics = client.diagnostics_for --path=path2
  expect_equals 0 diagnostics.size
