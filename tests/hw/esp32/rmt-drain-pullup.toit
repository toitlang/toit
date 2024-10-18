// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the bidirectional open-drain/pull-up functionality of the RMT peripheral.

Setup:
Connect pin 18 and 19 with a 330 Ohm (or any other 300-1K) resistor.
Connect pin 18 to pin 34.
Connect pin 18 to GND with a 1M Ohm resistor (or any other big number).
*/

import rmt
import gpio
import monitor
import expect show *

RMT-PIN ::= 18
LEVEL-PIN ::= 19
MEASURE-PIN ::= 34

main:
  2.repeat:
    test-no-pull-up --idle-level=it
    test-pull-up --idle-level=it
  print "All tests passed."

test-no-pull-up --idle-level/int:
  print "Testing no pull up idle_level=$idle-level"
  measure-pin := gpio.Pin MEASURE-PIN --input

  rmt-pin := gpio.Pin RMT-PIN

  out := rmt.Channel rmt-pin --output --idle-level=idle-level
  in := rmt.Channel rmt-pin --input
  // We actually don't need the bidirectionality here, but by
  // making the channel bidirectional it switches to open drain.
  rmt.Channel.make-bidirectional --in=in --out=out

  // Give the 1M resistor time to drain.
  sleep --ms=1
  // Due to the 1M resistor, the pin is pulled to GND.
  // Remember: a pin with open-drain basically disconnects when being set to 1.
  expect-equals 0 measure-pin.get

  // Disable open-drain.
  rmt-pin.set-open-drain false
  expect-equals idle-level measure-pin.get

  // Enable it again.
  rmt-pin.set-open-drain true
  // Give the 1M resistor time to drain.
  sleep --ms=1
  expect-equals 0 measure-pin.get

  // Connect the level pin.
  // It should win over the open-drain as long as the rmt_pin is high (and thus disconnected).
  // If the idle_level is low, then the rmt_pin wins.
  level-pin := gpio.Pin LEVEL-PIN --output
  level-pin.set 1
  expect-equals idle-level measure-pin.get

  level-pin.set 0
  expect-equals 0 measure-pin.get

  out.close
  in.close
  rmt-pin.close
  measure-pin.close
  level-pin.close

test-pull-up --idle-level/int:
  print "Testing with pull up idle_level=$idle-level"
  measure-pin := gpio.Pin MEASURE-PIN --input

  rmt-pin := gpio.Pin RMT-PIN

  out := rmt.Channel rmt-pin --output --idle-level=idle-level
  in := rmt.Channel rmt-pin --input
  // We actually don't need the bidirectionality here, but by
  // making the channel bidirectional it switches to open drain.
  rmt.Channel.make-bidirectional --in=in --out=out --pull-up

  if idle-level == 0:
    // The open drain wins over the 1M resistor.
    expect-equals 0 measure-pin.get
  else:
    // The internal pull-up wins over the 1M resistor.
    expect-equals 1 measure-pin.get

  // Disable open-drain.
  rmt-pin.set-open-drain false
  expect-equals idle-level measure-pin.get

  // Enable it again.
  rmt-pin.set-open-drain true
  if idle-level == 0:
    // The open drain wins over the 1M resistor.
    expect-equals 0 measure-pin.get
  else:
    // The internal pull-up wins over the 1M resistor.
    expect-equals 1 measure-pin.get

  // Connect the level pin.
  // It should win over the open-drain and pullup as long as the rmt_pin is high (and thus disconnected).
  level-pin := gpio.Pin LEVEL-PIN --output
  level-pin.set 1
  if idle-level == 0:
    // The open-drain wins.
    expect-equals 0 measure-pin.get
  else:
    expect-equals 1 measure-pin.get

  level-pin.set 0
  // The level pin wins over the pullup (if the idle-level is 1).
  // Otherwise they both agree anyway.
  expect-equals 0 measure-pin.get

  out.close
  in.close
  rmt-pin.close
  measure-pin.close
  level-pin.close
