// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import .test
import .uart-rs485-shared
import .variants

/**
Tests that the uart in rs485-half-duplex can receive data as soon as the
  RTS bit is cleared.
*/

RTS ::= Variant.CURRENT.connected-pin2
RX ::= Variant.CURRENT.connected-pin1
TX ::= Variant.CURRENT.unconnected-pin1

main:
  run-test: test

test:
  rx := gpio.Pin RX
  tx := gpio.Pin TX
  rts := gpio.Pin RTS

  port := uart.Port
      --rx=rx
      --tx=tx
      --rts=rts
      --baud-rate=9600
      --mode=uart.Port.MODE-RS485-HALF-DUPLEX

  task --background::
    sleep --ms=2000
    print "Timeout"
    print "Board1 must be started before board2."

  task::
    5.repeat:
      data := port.in.read
      if data != RESPONSE-MESSAGE:
        throw "Error: $data $data.to-string-non-throwing"

  5.repeat:
    port.out.write OUT-MESSAGE
    sleep --ms=100
