// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the i2c pull-up resistors.

Setup:
Connect pin 18 to pin 34.
Connect pin 18 to GND with a 1M Ohm resistor (or any other big number).
Pin 4 shoul not be connected.
*/

import expect show *
import gpio
import i2c

import .test

TEST-PIN := 18
OTHER-PIN := 4
MEASURE-PIN := 34

main:
  run-test: test

test:
  test-pin := gpio.Pin TEST-PIN
  other-pin := gpio.Pin OTHER-PIN
  measure-pin := gpio.Pin MEASURE-PIN --input

  // Test no pull-up.
  bus := i2c.Bus --sda=test-pin --scl=other-pin --frequency=100_000
  expect-equals 0 measure-pin.get  // The 1M resistor pulls the pin to GND.
  bus.close
  bus = i2c.Bus --sda=other-pin --scl=test-pin --frequency=100_000
  expect-equals 0 measure-pin.get  // The 1M resistor pulls the pin to GND.
  bus.close
  bus = i2c.Bus --sda=test-pin --scl=other-pin --frequency=100_000 --scl-pullup
  expect-equals 0 measure-pin.get  // The 1M resistor pulls the pin to GND.
  bus.close
  bus = i2c.Bus --sda=other-pin --scl=test-pin --frequency=100_000 --sda-pullup
  expect-equals 0 measure-pin.get  // The 1M resistor pulls the pin to GND.
  bus.close

  // Test the pull-up.
  bus = i2c.Bus --sda=test-pin --scl=other-pin --frequency=100_000 --sda-pullup
  expect-equals 1 measure-pin.get  // The internal pull-up wins over the 1M resistor.
  bus.close
  bus = i2c.Bus --sda=other-pin --scl=test-pin --frequency=100_000 --scl-pullup
  expect-equals 1 measure-pin.get  // The internal pull-up wins over the 1M resistor.
  bus.close
  bus = i2c.Bus --sda=test-pin --scl=other-pin --frequency=100_000 --sda-pullup --scl-pullup
  expect-equals 1 measure-pin.get  // The internal pull-up wins over the 1M resistor.
  bus.close
  bus = i2c.Bus --sda=other-pin --scl=test-pin --frequency=100_000 --sda-pullup --scl-pullup
  expect-equals 1 measure-pin.get  // The internal pull-up wins over the 1M resistor.
  bus.close
