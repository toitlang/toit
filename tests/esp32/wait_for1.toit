// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import monitor
import rmt

/**
Tests the $gpio.Pin.wait_for functionality.

# Setup
You need two boards.
- Connect GND of board1 to GND of board2.
- Connect pin 18 of board1 to pin 19 of board2.
- Connect pin 19 of board1 to pin 18 of board2.

Run `wait_for1.toit` on board1.
Once that one is running, run `wait_for2.toit` on board2.
*/

PIN_IN ::= 18
PIN_OUT ::= 19

ITERATIONS ::= 10_000
MEDIUM_PULSE_ITERATIONS ::= 50
SHORT_PULSE_ITERATIONS ::= 50
ULTRA_SHORT_PULSE_ITERATIONS ::= 50

MEDIUM_PULSE_DURATION_MS ::= 5

main:
  pin_in := gpio.Pin PIN_IN --input --pull_down
  pin_out := gpio.Pin PIN_OUT --output

  ITERATIONS.repeat: | counter |
    if counter % 1000 == 0: print "Iteration: $counter"
    for i := 0; i < (counter % 200); i++:
      null
    // In this mode the pin stays high as long as we don't get any response.
    pin_out.set 1
    while pin_in.get != 1: null
    pin_out.set 0
    while pin_in.get != 0: null

  sleep --ms=500

  print "sending $(MEDIUM_PULSE_DURATION_MS)ms pulses"
  MEDIUM_PULSE_ITERATIONS.repeat:
    sleep --ms=10
    pin_out.set 1
    sleep --ms=MEDIUM_PULSE_DURATION_MS
    pin_out.set 0
  print "medium pulses done"
  pin_in.wait_for 1

  pin_in.wait_for 0
  print "sending short pulses"
  sleep --ms=300
  SHORT_PULSE_ITERATIONS.repeat:
    sleep --ms=10
    pin_out.set 1
    pin_out.set 0

  print "short pulses done"
  pin_in.wait_for 1

  print "sending ultra short pulses"
  channel := rmt.Channel pin_out --output
  signals := rmt.Signals 2
  signals.set 0 --period=1 --level=1
  signals.set 1 --period=0 --level=0

  sleep --ms=300

  ULTRA_SHORT_PULSE_ITERATIONS.repeat:
    sleep --ms=10
    channel.write signals

  print "done"
