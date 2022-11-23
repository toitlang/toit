// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import monitor
import .wait_for1 show
  ITERATIONS MEDIUM_PULSE_ITERATIONS SHORT_PULSE_ITERATIONS ULTRA_SHORT_PULSE_ITERATIONS

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
    exception := catch: with_timeout --ms=2_000:
      pin_in.wait_for 1
    if exception:
      print "Iteration: $iteration"
      throw exception
    expect_equals 1 pin_in.get

    pin_out.set 1
    while pin_in.get != 0: null
    pin_out.set 0

  print "Looking for medium pulses"
  with_timeout --ms=(500 + 300 * MEDIUM_PULSE_ITERATIONS):
    MEDIUM_PULSE_ITERATIONS.repeat: | iteration |
      pin_in.wait_for 1
      pin_in.wait_for 0

  pin_out.set 1
  sleep --ms=100

  print "Looking for short pulses"
  pin_out.set 0
  with_timeout --ms=(500 + 300 * SHORT_PULSE_ITERATIONS):
    SHORT_PULSE_ITERATIONS.repeat:
      pin_in.wait_for 1
      pin_in.wait_for 0

  pin_out.set 1
  sleep --ms=100

  print "Looking for ultra short pulses"

  count := 0
  pin_out.set 0
  exception := catch:
    with_timeout --ms=(500 + 30 * ULTRA_SHORT_PULSE_ITERATIONS):
      ULTRA_SHORT_PULSE_ITERATIONS.repeat:
        pin_in.wait_for 1
        pin_in.wait_for 0
        count++

  if exception:
    print "count: $count"
    throw exception

  pin_out.set 1

  sleep --ms=100  // Give wait_for1 time to see the last 0.
  print "done"
