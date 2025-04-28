// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the errors of i2c.

Setup:
Pin 2 and pin 4 should not be connected.
*/

import expect show *
import gpio
import i2c

import .test
import .variants

SDA-PIN := Variant.CURRENT.unconnected-pin1
SCL-PIN := Variant.CURRENT.unconnected-pin2

main:
  run-test: test

test:
  bus := i2c.Bus
      --sda=gpio.Pin SDA-PIN
      --scl=gpio.Pin SCL-PIN
      --frequency=100_000

  device := bus.device 123

  expect-throw "ESP_ERR_INVALID_STATE": device.read 1
  expect-throw "ESP_ERR_INVALID_STATE": device.write #[1, 2, 3]
