// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import monitor
import rmt
import system

import .test
import .wait-for1-shared

/**
See 'wait-for1-shared.toit'.
*/

MEDIUM-PULSE-DURATION-MS ::= 5

main:
  run-test: test

test:
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

  clk-div/int := ?
  if system.architecture == system.ARCHITECTURE-ESP32:
    // For some reason we seem to miss one pulse if we run at 80MHz.
    // 40MHz seems to be fine, though.
    clk-div = 2
  else:
    // For non ESP32 devices the datasheet requires:
    //  3 × T_apb_clk + 5 × T_rmt_sclk < period × T_clk_div
    // We set the clk-div to 9, and the period to 1.
    clk-div = 9

  channel := rmt.Out pin-out --resolution=(80_000_000 / clk-div)
  signals := rmt.Signals 2
  signals.set 0 --period=1 --level=1
  signals.set 1 --period=0 --level=0

  sleep --ms=300

  ULTRA-SHORT-PULSE-ITERATIONS.repeat:
    sleep --ms=10
    channel.write signals
