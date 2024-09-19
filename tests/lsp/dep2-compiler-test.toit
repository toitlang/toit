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
  drive := platform == system.PLATFORM-WINDOWS ? "c:" : ""
  relative-module1 := "some_non_existing_path1"
  relative-module2 := "some_non_existing_path2"
  path1 := "$drive/$(relative-module1).toit"
  path2 := "$drive/$(relative-module2).toit"

  client.send-did-open --path=path1 --text=""
  client.send-did-open --path=path2 --text=""

  diagnostics := client.diagnostics-for --path=path1
  expect-equals 0 diagnostics.size
  diagnostics = client.diagnostics-for --path=path2
  expect-equals 0 diagnostics.size

  client.send-did-change --path=path1 """
    main:
      foo // Error because 'foo' is unresolved
    """
  diagnostics = client.diagnostics-for --path=path1
  expect-equals 1 diagnostics.size
  diagnostics = client.diagnostics-for --path=path2
  expect-equals 0 diagnostics.size

  client.send-did-change --path=path1 """
    import .$relative-module2
    main:
      foo
    """

  client.send-did-change --path=path2 """
    foo: return 134
    """

  diagnostics = client.diagnostics-for --path=path1
  expect-equals 0 diagnostics.size
  diagnostics = client.diagnostics-for --path=path2
  expect-equals 0 diagnostics.size

  client.send-did-change --path=path1 """
    import .$relative-module2
    main:
      foo 1  // Error because arguments don't match.
    """
  diagnostics = client.diagnostics-for --path=path1
  expect-equals 1 diagnostics.size

  client.clear-diagnostics

  diagnostics = client.diagnostics-for --path=path1
  expect-null diagnostics
  diagnostics = client.diagnostics-for --path=path2
  expect-null diagnostics

  client.send-did-change --path=path2 """
    foo: return 499  // <=== Changed number here.
    """

  // The summary of path2 didn't change, and therefore there aren't any diagnostics for path1 again.
  diagnostics = client.diagnostics-for --path=path1
  expect-null diagnostics
  diagnostics = client.diagnostics-for --path=path2
  expect-equals 0 diagnostics.size

  client.send-did-change --path=path2 """
    foo: return 499
    bar: return 42   // <=== New function
    """

  // The summary of path2 changed, and therefore there are diagnostics for path1 again.
  diagnostics = client.diagnostics-for --path=path1
  expect-equals 1 diagnostics.size
  diagnostics = client.diagnostics-for --path=path2
  expect-equals 0 diagnostics.size

  client.clear-diagnostics

  client.send-did-change --path=path2 """
    foo x: return 499  // <=== Adds parameter
    bar: return 42
    """

  // The summary of path2 changed, and therefore there are diagnostics for path1 again.
  diagnostics = client.diagnostics-for --path=path1
  expect-equals 0 diagnostics.size
  diagnostics = client.diagnostics-for --path=path2
  expect-equals 0 diagnostics.size
