// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .test

/**
Tests the $gpio.Pin.wait-for functionality while a parallel
  task closes the pin.

# Setup
- Connect IO34 to GND with a 330+ Ohm resistor. 1MOhm is fine.
*/

PIN-IN ::= 34

main:
  run-test: test

test:
  pin-in := gpio.Pin PIN-IN --input

  task::
    sleep --ms=500
    print "shutting down pin"
    pin-in.close

  print "waiting for pin to go high"
  pin-in.wait-for 1
