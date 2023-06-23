// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

/**
Tests the $gpio.Pin.wait_for functionality while a parallel
  task closes the pin.

# Setup
- Connect IO34 to GND with a 330+ Ohm resistor. 1MOhm is fine.
*/

PIN_IN ::= 34

main:
  pin_in := gpio.Pin PIN_IN --input

  task::
    sleep --ms=500
    print "shutting down pin"
    pin_in.close

  print "waiting for pin to go high"
  pin_in.wait_for 1

  print "done"
