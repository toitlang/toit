/*  */// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests changing the open-drain setting of gpio pins.

Setup:
Connect pin 18 and 19 with a 330 Ohm (or any other 300-1K) resistor.
Connect pin 18 to pin 32.
Connect pin 18 to GND with a 1M Ohm resistor (or any other big number).
*/

import gpio
import uart
import expect show *

TEST_PIN ::= 18
LEVEL_PIN ::= 19
MEASURE_PIN ::= 32

main:
  test_gpio
  print "All tests done"

test_gpio:
  measure_pin := gpio.Pin MEASURE_PIN --input

  test_pin := gpio.Pin TEST_PIN --output

  // The pin is in full output mode and should just win.
  expect_equals 0 measure_pin.get
  test_pin.set 1
  expect_equals 1 measure_pin.get
  test_pin.set 0

  // Enable open drain.
  test_pin.set_open_drain true

  expect_equals 0 measure_pin.get
  test_pin.set 1
  // The 1MOhm resistor wins now.
  expect_equals 0 measure_pin.get

  level_pin := gpio.Pin LEVEL_PIN --output
  level_pin.set 1

  // The 330Ohm resistor wins now.
  expect_equals 1 measure_pin.get

  level_pin.set 0
  expect_equals 0 measure_pin.get

  test_pin.set 0
  expect_equals 0 measure_pin.get

  level_pin.set 1
  // The test pin is draining.
  expect_equals 0 measure_pin.get

  level_pin.close

  // Switch back to non-open-drain.
  test_pin.set_open_drain false

  expect_equals 0 measure_pin.get
  test_pin.set 1
  expect_equals 1 measure_pin.get
  test_pin.set 0
  expect_equals 0 measure_pin.get

  // Try with a pull-up.

  test_pin.configure --pull_up --input --output --open_drain
  // 0 drains.
  expect_equals 0 measure_pin.get
  test_pin.set 1
  // Now the pull up wins (and not the 1M resistor).
  expect_equals 1 measure_pin.get


  // It's not recommended, but we can switch to non-open-drain.
  test_pin.set_open_drain false

  expect_equals 1 measure_pin.get
  test_pin.set 0
  expect_equals 0 measure_pin.get

  measure_pin.close
  test_pin.close
  level_pin.close
