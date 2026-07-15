// Copyright (C) 2025 Toit contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that dropped packages lead to an error.

For the setup see the comment near $Variant.uart-error-in1.
*/

import expect show *
import uart

import .test
import .variants

// Not that RX1 goes to TX2 and TX1 goes to RX2.
RX1 ::= Variant.CURRENT.uart-error-in2
TX1 ::= Variant.CURRENT.uart-error-out1

RX2 ::= Variant.CURRENT.uart-error-in1
TX2 ::= Variant.CURRENT.uart-error-out2

main:
  run-test: test

test:
  succeeded := false

  port1 := uart.Port
      --rx=RX1
      --tx=TX1
      --baud-rate=115200

  port2 := uart.Port
      --rx=RX2
      --tx=TX2
      --baud-rate=115200

  expect-equals 0 port1.errors
  expect-equals 0 port2.errors

  // Write to port1 without reading from port2.
  task --background::
    while true:
      port1.out.write "toit toit toit toit"
      yield

  // Expect that port2 will get an error because it doesn't read.
  while port2.errors == 0:
    sleep --ms=10

  current-errors := port2.errors
  print "Errors: $current-errors"
  port2.in.read  // So we get a log message about the error.

  while port2.errors == current-errors:
    sleep --ms=10

  print "Errors: $port2.errors"
  port2.in.read  // We shouldn't get a log message anymore.

  port1.close
  port2.close
