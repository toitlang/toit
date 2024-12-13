// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import uart

import .test

/**
Tests that the UART buffer doesn't start with garbage in it when
  initialized as rs485 half-duplex.

Setup:
  Uses pin 16 and 23. They should stay unconnected or connected to
  a high-impedance pin.
*/

main:
  run-test: test

test:
  rx := gpio.Pin 16
  rts := gpio.Pin 23
  port := uart.Port
      --rx=rx
      --tx=null
      --rts=rts
      --baud-rate=9600
      --mode=uart.Port.MODE-RS485-HALF-DUPLEX
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=200:
      data := port.in.read
      print "Got garbage: $data"
  port.close
  rts.close
  rx.close
