// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests reading, writing, and changing the baud rate of the console UART.

The esp-tester watches the test's output for request markers and responds over
  the same serial connection.

No wiring is needed: the test uses the USB-serial connection that also
  carries the console output.
*/

import expect show *
import uart

import ..esp-tester.shared show UART-BAUD-RATE-ACK
                                UART-BAUD-RATE-REQUEST
                                UART-INPUT-REQUEST
import .test

MESSAGE ::= "hello-console"
CONSOLE-BAUD-RATE ::= 115_200
TEST-BAUD-RATE ::= 57_600
BAUD-RATE-TOLERANCE ::= 20

expect-baud expected/int actual/int:
  // UART dividers are rounded slightly differently across chips.
  expect (expected - BAUD-RATE-TOLERANCE) <= actual <= (expected + BAUD-RATE-TOLERANCE)

expect-input port/uart.Port expected/string:
  data := #[]
  with-timeout --ms=30_000:
    while data.size < expected.size:
      data += port.in.read
  expect-equals expected data.to-string

request-input port/uart.Port payload/string:
  port.out.write "$UART-INPUT-REQUEST$payload\n" --flush
  expect-input port "$payload\n"

change-baud-rate port/uart.Port rate/int:
  port.out.write "$UART-BAUD-RATE-REQUEST$rate\n" --flush
  // The tester sends this at the old rate and switches after it has drained.
  expect-input port "$UART-BAUD-RATE-ACK\n"
  port.baud-rate = rate
  expect-baud rate port.baud-rate
  // Give the tester time to update its host port before transmitting at the
  // new rate.
  sleep --ms=200

main:
  run-test: test

test:
  port := uart.Port.console
  expect-baud CONSOLE-BAUD-RATE port.baud-rate
  // Opening the console port a second time must fail.
  expect-throw "ALREADY_IN_USE": uart.Port.console
  request-input port MESSAGE
  // Writing to the console port must work as well. The bytes simply show up
  // in the test output, interleaved with the system's own output.
  port.out.write "console-write-works\n" --flush

  change-baud-rate port TEST-BAUD-RATE
  request-input port MESSAGE
  change-baud-rate port CONSOLE-BAUD-RATE

  port.close
  // After closing, the console port can be opened again.
  port2 := uart.Port.console
  port2.close
