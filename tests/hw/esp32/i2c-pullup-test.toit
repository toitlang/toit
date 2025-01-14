// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the i2c pull-up resistors.

For the setup see the documentation near $Variant.i2c-pullup-test-pin.
*/

import expect show *
import gpio
import i2c

import .test
import .variants

TEST-PIN := Variant.CURRENT.i2c-pullup-test-pin
OTHER-PIN := Variant.CURRENT.i2c-pullup-other-pin
MEASURE-PIN := Variant.CURRENT.i2c-pullup-measure-pin

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
