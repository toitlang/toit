// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the bidirectional open-drain/pull-up functionality of the RMT peripheral.

Setup:
Connect pin 18 and 19 with a 330 Ohm (or any other 300-1K) resistor.
Connect pin 18 to pin 32.
Connect pin 18 to GND with a 1M Ohm resistor (or any other big number).
*/

import rmt
import gpio
import monitor
import expect show *

RMT_PIN ::= 18
LEVEL_PIN ::= 19
MEASURE_PIN ::= 32

main:
  2.repeat:
    test_no_pull_up --idle_level=it
    test_pull_up --idle_level=it
  print "All tests passed."

test_no_pull_up --idle_level/int:
  print "Testing no pull up idle_level=$idle_level"
  measure_pin := gpio.Pin MEASURE_PIN --input

  rmt_pin := gpio.Pin RMT_PIN

  out := rmt.Channel rmt_pin --output --idle_level=idle_level
  in := rmt.Channel rmt_pin --input
  // We actually don't need the bidirectionality here, but by
  // making the channel bidirectional it switches to open drain.
  rmt.Channel.make_bidirectional --in=in --out=out

  // Give the 1M resistor time to drain.
  sleep --ms=1
  // Due to the 1M resistor, the pin is pulled to GND.
  // Remember: a pin with open-drain basically disconnects when being set to 1.
  expect_equals 0 measure_pin.get

  // Disable open-drain.
  rmt_pin.set_open_drain false
  expect_equals idle_level measure_pin.get

  // Enable it again.
  rmt_pin.set_open_drain true
  // Give the 1M resistor time to drain.
  sleep --ms=1
  expect_equals 0 measure_pin.get

  // Connect the level pin.
  // It should win over the open-drain as long as the rmt_pin is high (and thus disconnected).
  // If the idle_level is low, then the rmt_pin wins.
  level_pin := gpio.Pin LEVEL_PIN --output
  level_pin.set 1
  expect_equals idle_level measure_pin.get

  level_pin.set 0
  expect_equals 0 measure_pin.get

  out.close
  in.close
  rmt_pin.close
  measure_pin.close
  level_pin.close

test_pull_up --idle_level/int:
  print "Testing with pull up idle_level=$idle_level"
  measure_pin := gpio.Pin MEASURE_PIN --input

  rmt_pin := gpio.Pin RMT_PIN

  out := rmt.Channel rmt_pin --output --idle_level=idle_level
  in := rmt.Channel rmt_pin --input
  // We actually don't need the bidirectionality here, but by
  // making the channel bidirectional it switches to open drain.
  rmt.Channel.make_bidirectional --in=in --out=out --pull_up

  if idle_level == 0:
    // The open drain wins over the 1M resistor.
    expect_equals 0 measure_pin.get
  else:
    // The internal pull-up wins over the 1M resistor.
    expect_equals 1 measure_pin.get

  // Disable open-drain.
  rmt_pin.set_open_drain false
  expect_equals idle_level measure_pin.get

  // Enable it again.
  rmt_pin.set_open_drain true
  if idle_level == 0:
    // The open drain wins over the 1M resistor.
    expect_equals 0 measure_pin.get
  else:
    // The internal pull-up wins over the 1M resistor.
    expect_equals 1 measure_pin.get

  // Connect the level pin.
  // It should win over the open-drain and pullup as long as the rmt_pin is high (and thus disconnected).
  level_pin := gpio.Pin LEVEL_PIN --output
  level_pin.set 1
  if idle_level == 0:
    // The open-drain wins.
    expect_equals 0 measure_pin.get
  else:
    expect_equals 1 measure_pin.get

  level_pin.set 0
  // The level pin wins over the pullup (if the idle-level is 1).
  // Otherwise they both agree anyway.
  expect_equals 0 measure_pin.get

  out.close
  in.close
  rmt_pin.close
  measure_pin.close
  level_pin.close
