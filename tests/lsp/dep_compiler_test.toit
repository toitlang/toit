// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  client.always_wait_for_idle = false

  // Start by opening the protocol* files.
  // We will modify all of them, but this way we have file-names that
  // we can use to import relatively.
  protocol1 := "$(directory.cwd)/protocol1.toit"
  protocol2 := "$(directory.cwd)/protocol2.toit"
  protocol3 := "$(directory.cwd)/protocol3.toit"
  files_to_open := [ protocol1, protocol2, protocol3 ]

  files_to_open.do: | test |
    client.send_did_open --path=test

  client.wait_for_idle

  print "Changing protocol1"
  client.send_did_change --path=protocol1 """
    import .protocol2

    interface A:
      foo
    """
  print "Changing protocol2"
  client.send_did_change --path=protocol2 """
    import .protocol1

    class B implements A:
      bar: return 499
    """

  client.wait_for_idle

  diagnostics := client.diagnostics_for --path=protocol2
  // One error because of 'foo' not implemented in 'B'
  expect_equals 1 diagnostics.size

  print "Changing protocol1 again"
  client.send_did_change --path=protocol1 """
    import .protocol2

    interface A:
      bar  // Now 'bar' instead of 'foo'
    """

  client.wait_for_idle

  diagnostics = client.diagnostics_for --path=protocol2
  // No errors anymore.
  expect_equals 0 diagnostics.size

  print "--- Different test ---"

  print "Changing protocol1"
  client.send_did_change --path=protocol1 """
    interface A:
      foo
    """
  print "Changing protocol2"
  client.send_did_change --path=protocol2 """
    import .protocol1

    class B implements A:
      bar: return 499
    """

  print "Changing protocol3"
  client.send_did_change --path=protocol3 """
    import .protocol2

    main: B
    """

  client.wait_for_idle

  diagnostics = client.diagnostics_for --path=protocol2
  // One error because of 'foo' not implemented in 'B'
  expect_equals 1 diagnostics.size

  print "Changing protocol1 again"
  client.send_did_change --path=protocol1 """
    interface A:
      bar  // Now 'bar' instead of 'foo'
    """

  // There is a race condition if we don't wait for the server to be
  // idle.
  client.wait_for_idle

  print "Changing protocol3 again"
  client.send_did_change --path=protocol3 """
    import .protocol2

    main: B  // No real change.
    """

  client.wait_for_idle

  diagnostics = client.diagnostics_for --path=protocol2
  // No errors anymore.
  expect_equals 0 diagnostics.size
