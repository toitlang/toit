// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests changing the open-drain setting of gpio pins.

Setup:
Connect test-pin and level-pin with a 330 Ohm (or any other 300-1K) resistor.
Connect test-pin to measure-pin.
Connect test-pin to GND with a 1M Ohm resistor (or any other big number).

test-pin should be configured as output.
measure-pin should be configured as input
level-pin should be configured as not-output (input or nothing) and will be
  reconfigured as output
*/

import gpio
import expect show *

test-gpio --test-pin/gpio.Pin --measure-pin/gpio.Pin --level-pin/gpio.Pin:
  // The pin is in full output mode and should just win.
  expect-equals 0 measure-pin.get
  test-pin.set 1
  expect-equals 1 measure-pin.get
  test-pin.set 0

  // Enable open drain.
  test-pin.set-open-drain true

  expect-equals 0 measure-pin.get
  test-pin.set 1
  // The 1MOhm resistor wins now.
  expect-equals 0 measure-pin.get

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

  test-pin.configure --pull-up --input --output --open-drain
  // 0 drains.
  expect-equals 0 measure-pin.get
  test-pin.set 1
  // Now the pull up wins (and not the 1M resistor).
  expect-equals 1 measure-pin.get


  // It's not recommended, but we can switch to non-open-drain.
  test-pin.set-open-drain false

  expect-equals 1 measure-pin.get
  test-pin.set 0
  expect-equals 0 measure-pin.get
