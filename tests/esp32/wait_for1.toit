// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import monitor

/**
Tests the $gpio.Pin.wait_for functionality.

# Setup
You need two boards.
- Connect GND of board1 to GND of board2.
- Connect pin 18 of board1 to pin 19 of board2.
- Connect pin 19 of board1 to pin 18 of board2.

Run `wait_for1.toit` on board1.
Once that one is running, run `wait_for2.toit` on board2.
*/

PIN_IN ::= 18
PIN_OUT ::= 19

ITERATIONS ::= 10_000

main:
  pin_in := gpio.Pin PIN_IN --input --pull_down
  pin_out := gpio.Pin PIN_OUT --output
  sleep --ms=100

  ITERATIONS.repeat: | counter |
    if counter % 1000 == 0: print "Iteration: $counter"
    for i := 0; i < (counter % 200); i++:
      null
    pin_out.set 1
    while pin_in.get != 1: null
    pin_out.set 0
    while pin_in.get != 0: null

  print "done"
