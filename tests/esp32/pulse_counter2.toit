// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the pulse_counter library is correctly releasing the resources
  when the process shuts down.
*/

import expect show *
import gpio
import pulse_counter

IN1 /int ::= 18
IN2 /int ::= 25

allocate_unit --error/bool=false:
  in := gpio.Pin IN1
  unit := pulse_counter.Unit
  channel := unit.add_channel in
  if error: throw "fail"

main:
  10.repeat:
    process := spawn::
      allocate_unit
    sleep --ms=20

  10.repeat:
    spawn::
      allocate_unit --error
    sleep --ms=20
