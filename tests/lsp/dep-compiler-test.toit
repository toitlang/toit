// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *

main args:
  run-client-test args: test it

test client/LspClient:
  client.always-wait-for-idle = false

  // Start by opening the protocol* files.
  // We will modify all of them, but this way we have file-names that
  // we can use to import relatively.
  protocol1 := "$(directory.cwd)/protocol1.toit"
  protocol2 := "$(directory.cwd)/protocol2.toit"
  protocol3 := "$(directory.cwd)/protocol3.toit"
  files-to-open := [ protocol1, protocol2, protocol3 ]

  files-to-open.do: | test |
    client.send-did-open --path=test

  client.wait-for-idle

  print "Changing protocol1"
  client.send-did-change --path=protocol1 """
    import .protocol2

    interface A:
      foo
    """
  print "Changing protocol2"
  client.send-did-change --path=protocol2 """
    import .protocol1

    class B implements A:
      bar: return 499
    """

  client.wait-for-idle

  diagnostics := client.diagnostics-for --path=protocol2
  // One error because of 'foo' not implemented in 'B'
  expect-equals 1 diagnostics.size

  print "Changing protocol1 again"
  client.send-did-change --path=protocol1 """
    import .protocol2

    interface A:
      bar  // Now 'bar' instead of 'foo'
    """

  client.wait-for-idle

  diagnostics = client.diagnostics-for --path=protocol2
  // No errors anymore.
  expect-equals 0 diagnostics.size

  print "--- Different test ---"

  print "Changing protocol1"
  client.send-did-change --path=protocol1 """
    interface A:
      foo
    """
  print "Changing protocol2"
  client.send-did-change --path=protocol2 """
    import .protocol1

    class B implements A:
      bar: return 499
    """

  print "Changing protocol3"
  client.send-did-change --path=protocol3 """
    import .protocol2

    main: B
    """

  client.wait-for-idle

  diagnostics = client.diagnostics-for --path=protocol2
  // One error because of 'foo' not implemented in 'B'
  expect-equals 1 diagnostics.size

  print "Changing protocol1 again"
  client.send-did-change --path=protocol1 """
    interface A:
      bar  // Now 'bar' instead of 'foo'
    """

  // There is a race condition if we don't wait for the server to be
  // idle.
  client.wait-for-idle

  print "Changing protocol3 again"
  client.send-did-change --path=protocol3 """
    import .protocol2

    main: B  // No real change.
    """

  client.wait-for-idle

  diagnostics = client.diagnostics-for --path=protocol2
  // No errors anymore.
  expect-equals 0 diagnostics.size
