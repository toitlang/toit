// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the pulse_counter library is correctly releasing the resources
  when the process shuts down.
*/

import expect show *
import gpio
import pulse-counter

import .test
import .variants

IN/int ::= Variant.CURRENT.unconnected-pin1

allocate-unit --close/bool=false:
  in := gpio.Pin IN
  unit := pulse-counter.Unit in
  if close:
    unit.close

main:
  run-test: test

test:
  print "Closing correctly"
  10.repeat:
    spawn::
      allocate-unit --close
    sleep --ms=20

  print "Not closing"
  10.repeat:
    spawn::
      allocate-unit
    sleep --ms=20
