// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that the UART flush is working.

Setup:
Connect GND of one ESP32 to GND of another ESP32.
Connect pin 22 of the first ESP32 to pin 23 of the second ESP32.
Connect pin 23 of the first ESP32 to pin 22 of the second ESP32.

Run uart-flush2-board1.toit on one ESP32 and uart-flush2-board2.toit on the other.
*/

import gpio
import uart

RX ::= 22
SIGNAL ::= 23

main:
  rx := gpio.Pin RX --input --pull-up
  signal := gpio.Pin SIGNAL --input --pull-up

  5.repeat:
    signal.wait-for 0
    while signal.get == 0:
      // Do nothing.
    start := Time.monotonic-us
    while Time.monotonic-us - start < 100_000:
      if rx.get == 0:
        throw "Got bit after signal went low"
  rx.close
  signal.close
