// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import gpio
import uart

import .test
import .uart-rs485-shared
import .variants

RTS ::= Variant.CURRENT.board-connection-pin1
TX ::= Variant.CURRENT.board-connection-pin2

main:
  run-test: test

test:
  rts := gpio.Pin --input RTS --pull-down
  tx := gpio.Pin TX

  port := uart.Port
      --rx=null
      --tx=tx
      --baud-rate=9600

  5.repeat:
    while rts.get == 0:
    while rts.get == 1:
    port.out.write RESPONSE-MESSAGE
