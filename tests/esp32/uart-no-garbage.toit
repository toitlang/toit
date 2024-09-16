// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import uart

/**
Tests that the UART buffer doesn't start with garbage in it.

Setup:
  IO16 must stay unconnected.

Run this test after a reboot, and then run the test twice without rebooting.
*/

main:
  rx := gpio.Pin 22
  port := uart.Port --rx=rx --tx=null --baud-rate=9600
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=200:
      data := port.in.read
      print "Got garbage: $data"
  port.close
  rx.close
