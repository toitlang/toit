// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests reading input from the console UART.

The esp-tester watches the test's output for the $UART-INPUT-REQUEST marker
  and writes the payload back over the same serial connection.

No wiring is needed: the test uses the USB-serial connection that also
  carries the console output.
*/

import expect show *
import uart

import ..esp-tester.shared show UART-INPUT-REQUEST
import .test

MESSAGE ::= "hello-console"

main:
  run-test: test

test:
  port := uart.Port.console
  // Opening the console port a second time must fail.
  expect-throw "ALREADY_IN_USE": uart.Port.console
  print "$UART-INPUT-REQUEST$MESSAGE"
  data := #[]
  with-timeout --ms=30_000:
    while data.size < MESSAGE.size + 1:
      data += port.in.read
  expect-equals "$MESSAGE\n" data.to-string
  // Writing to the console port must work as well. The bytes simply show up
  // in the test output, interleaved with the system's own output.
  port.out.write "console-write-works\n"
  port.close
  // After closing, the console port can be opened again.
  port2 := uart.Port.console
  port2.close
