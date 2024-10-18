// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import monitor
import rmt
import .wait-for1-shared

/**
See 'wait-for1-shared.toit'.
*/

MEDIUM-PULSE-DURATION-MS ::= 5

main:
  pin-in := gpio.Pin PIN-IN --input --pull-down
  pin-out := gpio.Pin PIN-OUT --output

  ITERATIONS.repeat: | counter |
    if counter % 1000 == 0: print "Iteration: $counter"
    for i := 0; i < (counter % 200); i++:
      null
    // In this mode the pin stays high as long as we don't get any response.
    pin-out.set 1
    while pin-in.get != 1: null
    pin-out.set 0
    while pin-in.get != 0: null

  sleep --ms=500

  print "sending $(MEDIUM-PULSE-DURATION-MS)ms pulses"
  MEDIUM-PULSE-ITERATIONS.repeat:
    sleep --ms=10
    pin-out.set 1
    sleep --ms=MEDIUM-PULSE-DURATION-MS
    pin-out.set 0
  print "medium pulses done"
  pin-in.wait-for 1

  pin-in.wait-for 0
  print "sending short pulses"
  sleep --ms=300
  SHORT-PULSE-ITERATIONS.repeat:
    sleep --ms=10
    pin-out.set 1
    pin-out.set 0

  print "short pulses done"
  pin-in.wait-for 1

  print "sending ultra short pulses"
  // For some reason we seem to miss one pulse if we run at 80MHz (clk_div=1).
  // 40MHz seems to be fine, though.
  channel := rmt.Channel pin-out --output --clk-div=2
  signals := rmt.Signals 2
  signals.set 0 --period=1 --level=1
  signals.set 1 --period=0 --level=0

  sleep --ms=300

  ULTRA-SHORT-PULSE-ITERATIONS.repeat:
    sleep --ms=10
    channel.write signals

  print "done"
