// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import monitor
import .wait_for1 show ITERATIONS

/**
See 'wait_for1.toit'.
*/

PIN_IN ::= 18
PIN_OUT ::= 19

main:
  pin_in := gpio.Pin PIN_IN --input
  pin_out := gpio.Pin PIN_OUT --output

  ITERATIONS.repeat: | iteration |
    if iteration % 1000 == 0: print "Iteration: $iteration"
    before := pin_in.get
    with_timeout --ms=2_000:
      pin_in.wait_for 1
    if pin_in.get != 1: throw "Expected pin to be 1 - $iteration $before"
    pin_out.set 1
    while pin_in.get != 0: null
    pin_out.set 0

  sleep --ms=100  // Give wait_for1 time to see the last 0.
  print "done"
