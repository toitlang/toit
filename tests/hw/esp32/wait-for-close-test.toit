// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .test
import .variants

/**
Tests the $gpio.Pin.wait-for functionality while a parallel
  task closes the pin.

For the setup see the comment near $Variant.wait-for-close-pin.
*/

PIN-IN ::= Variant.CURRENT.wait-for-close-pin

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
