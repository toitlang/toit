// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import expect show *

/**
Tests changing the open-drain setting of gpio pins.

Setup:
Connect $test-pin and $level-pin with a 330 Ohm (or any other 300-1K) resistor.
Connect $test-pin to $measure-pin.
Connect $test-pin to GND with a 1M Ohm resistor (or any other big number).

The $test-pin should be configured as output.
The $measure-pin should be configured as input
The $level-pin should be configured as not-output (input or nothing) and will be
  reconfigured as output
*/
test-gpio --test-pin/gpio.Pin --measure-pin/gpio.Pin --level-pin/gpio.Pin:
  print "GND <-1M-> $test-pin.num <-> $measure-pin.num <-330-> $level-pin.num"
  // The pin is in full output mode and should just win.
  expect-equals 0 measure-pin.get
  test-pin.set 1
  expect-equals 1 measure-pin.get
  test-pin.set 0

  test-pin.configure --input
  // The pin is in input mode and the 1MOhm resistor should win.
  expect-equals 0 measure-pin.get
  test-pin.set-pull 1  // Pull up.
  expect-equals 1 measure-pin.get
  test-pin.set-pull -1  // Pull down.
  // Given the 1MOhm resistor, we don't see a difference to the non-pull configuration,
  // but at least we know that something changed compared to the pull-up.
  expect-equals 0 measure-pin.get

  test-pin.configure --output

  // Enable open drain.
  test-pin.set-open-drain true

  expect-equals 0 measure-pin.get
  test-pin.set 1
  sleep --ms=1  // Give the 1MOhm resistor time to drain.
  // The 1MOhm resistor wins now.
  expect-equals 0 measure-pin.get

  test-pin.set-pull 1  // Pull up.
  // The internal pull up wins.
  expect-equals 1 measure-pin.get
  test-pin.set-pull 0  // Disable any pull.

  level-pin.configure --output
  level-pin.set 1

  // The 330Ohm resistor wins now.
  expect-equals 1 measure-pin.get

  level-pin.set 0
  expect-equals 0 measure-pin.get

  test-pin.set 0
  expect-equals 0 measure-pin.get

  level-pin.set 1
  // The test pin is draining.
  expect-equals 0 measure-pin.get

  level-pin.close

  // Switch back to non-open-drain.
  test-pin.set-open-drain false

  expect-equals 0 measure-pin.get
  test-pin.set 1
  expect-equals 1 measure-pin.get
  test-pin.set 0
  expect-equals 0 measure-pin.get

  // Try with a pull-up.

  test-pin.configure --input --pull-up

  expect-equals 1 measure-pin.get

  // Disable the pull-up.
  test-pin.set-pull 0
  sleep --ms=1  // Give the 1MOhm resistor time to drain.
  // The 1MOhm resistor wins now.
  expect-equals 0 measure-pin.get
  // Enable it again.
  test-pin.set-pull 1

  expect-equals 1 measure-pin.get

  test-pin.configure --pull-up --input --output --open-drain
  // 0 drains.
  expect-equals 0 measure-pin.get
  test-pin.set 1
  // Now the pull up wins (and not the 1M resistor).
  expect-equals 1 measure-pin.get

  // Disable the pull-up.
  test-pin.set-pull 0
  sleep --ms=1  // Give the 1MOhm resistor time to drain.
  // The 1MOhm resistor wins now.
  expect-equals 0 measure-pin.get
  // Enable it again.
  test-pin.set-pull 1

  // It's not recommended, but we can switch to non-open-drain.
  test-pin.set-open-drain false

  expect-equals 1 measure-pin.get
  test-pin.set 0
  expect-equals 0 measure-pin.get
