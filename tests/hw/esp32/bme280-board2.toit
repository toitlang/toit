// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bme280
import expect show *
import gpio
import i2c

import .test

main:
  run-test: test

test:
  scl := gpio.Pin 32
  sda := gpio.Pin 33
  bus := i2c.Bus --scl=scl --sda=sda
  device := bus.device bme280.I2C-ADDRESS-ALT
  driver := bme280.Driver device

  2.repeat:
    temperature := driver.read-temperature
    print temperature
    expect 12 < temperature < 35
    sleep --ms=200
