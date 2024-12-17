// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import monitor

import .test
import .wait-for1-shared

/**
See 'wait-for1-shared.toit'.
*/

main:
  run-test: test

test:
  pin-in := gpio.Pin PIN-IN --input
  pin-out := gpio.Pin PIN-OUT --output

  ITERATIONS.repeat: | iteration |
    if iteration % 1000 == 0: print "Iteration: $iteration"
    before := pin-in.get
    exception := catch: with-timeout --ms=2_000:
      pin-in.wait-for 1
    if exception:
      print "Iteration: $iteration"
      throw exception
    expect-equals 1 pin-in.get

    pin-out.set 1
    while pin-in.get != 0: null
    pin-out.set 0

  print "Looking for medium pulses"
  with-timeout --ms=(500 + 300 * MEDIUM-PULSE-ITERATIONS):
    MEDIUM-PULSE-ITERATIONS.repeat: | iteration |
      pin-in.wait-for 1
      pin-in.wait-for 0

  pin-out.set 1
  sleep --ms=100

  print "Looking for short pulses"
  pin-out.set 0
  with-timeout --ms=(500 + 300 * SHORT-PULSE-ITERATIONS):
    SHORT-PULSE-ITERATIONS.repeat:
      pin-in.wait-for 1
      pin-in.wait-for 0

  pin-out.set 1
  sleep --ms=100

  print "Looking for ultra short pulses"

  count := 0
  pin-out.set 0
  exception := catch:
    with-timeout --ms=(500 + 30 * ULTRA-SHORT-PULSE-ITERATIONS):
      ULTRA-SHORT-PULSE-ITERATIONS.repeat:
        pin-in.wait-for 1
        pin-in.wait-for 0
        count++

  if exception:
    print "count: $count"
    throw exception

  pin-out.set 1

  sleep --ms=100  // Give wait_for1 time to see the last 0.
