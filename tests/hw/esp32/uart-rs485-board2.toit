// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import .uart-rs485-shared
import gpio
import uart

RTS ::= 22
TX ::= 23

main:
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

  print "done"
