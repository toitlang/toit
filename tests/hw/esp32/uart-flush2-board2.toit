// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
See uart-flush2-board1.toit.
*/

import gpio
import uart

import .test
import .variants

TX ::= Variant.CURRENT.board-connection-pin1
SIGNAL ::= Variant.CURRENT.board-connection-pin2

main:
  run-test: test

test:
  port := uart.Port --tx=TX --rx=null --baud-rate=9600

  signal := gpio.Pin SIGNAL --output

  5.repeat:
    signal.set 0
    port.out.write "hello" --flush
    signal.set 1
    sleep --ms=200

  port.close
  signal.close
