// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import uart

import .test

/**
Tests that the UART buffer doesn't start with garbage in it.

Setup:
  Uses pin 16. The pin should stay unconnected or connected to
  a high-impedance pin.
*/

main:
  run-test: test

test:
  rx := gpio.Pin 16
  port := uart.Port --rx=rx --tx=null --baud-rate=500
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=200:
      data := port.in.read
      print "Got garbage: $data"
  port.close
  rx.close
