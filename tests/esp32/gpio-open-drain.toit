// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests changing the open-drain setting of gpio pins.

Setup:
Connect pin 18 and 19 with a 330 Ohm (or any other 300-1K) resistor.
Connect pin 18 to pin 34.
Connect pin 18 to GND with a 1M Ohm resistor (or any other big number).
*/

import gpio
import uart
import expect show *

TEST-PIN ::= 18
LEVEL-PIN ::= 19
MEASURE-PIN ::= 34

main:
  test-gpio
  print "All tests done"

test-gpio:
  measure-pin := gpio.Pin MEASURE-PIN --input

  test-pin := gpio.Pin TEST-PIN --output

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

  level-pin := gpio.Pin LEVEL-PIN --output
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

  measure-pin.close
  test-pin.close
  level-pin.close
