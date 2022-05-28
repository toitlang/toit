// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
Small example demonstrating the pulse counter.

Setup:
Connect pin 5 and 18 with a 330 Ohm resistor. The resistor isn't
  strictly necessary but can prevent accidental short circuiting.
*/

import pulse_counter
import gpio

main:
  // Pin 5 emits a square wave that can be counted by pin 18.
  out := gpio.Pin 5 --output
  square_task := task::
    while true:
      out.set 1
      sleep --ms=20
      out.set 0
      sleep --ms=20

  pin := gpio.Pin 18
  unit := pulse_counter.Unit
  channel := unit.add_channel pin

  5.repeat:
    print unit.value
    sleep --ms=500

  unit.close
  square_task.cancel
