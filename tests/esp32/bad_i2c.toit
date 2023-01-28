// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the errors of i2c.

Setup:
Pin 32 and pin 33 should not be connected.
*/

import expect show *
import gpio
import i2c

SDA_PIN := 32
SCL_PIN := 33

main:
  bus := i2c.Bus
      --sda=gpio.Pin SDA_PIN
      --scl=gpio.Pin SCL_PIN
      --frequency=100_000

  device := bus.device 123

  expect_throw "I2C_READ_FAILED": device.read 1
  expect_throw "I2C_WRITE_FAILED": device.write #[1, 2, 3]
