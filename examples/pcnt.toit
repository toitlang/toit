// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
Small example demonstrating the pulse counter.

Setup:
Connect pin 5 and 18 with a 330 Ohm resistor. The resistor isn't
  strictly necessary but can prevent accidental short circuiting.
*/

import pulse-counter
import gpio

OUT-PIN ::= 5
IN-PIN ::= 18

main:
  // The out pin emits a square wave that can be counted by the in pin.
  out := gpio.Pin OUT-PIN --output
  square-task := task::
    while true:
      out.set 1
      sleep --ms=20
      out.set 0
      sleep --ms=20

  unit := pulse-counter.Unit IN-PIN

  5.repeat:
    print unit.value
    sleep --ms=500

  unit.close
  square-task.cancel
