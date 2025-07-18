// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bme280
import expect show *
import gpio
import i2c

import .test
import .variants

main:
  run-test: test

test:
  scl := gpio.Pin Variant.CURRENT.board2-i2c-scl-pin
  sda := gpio.Pin Variant.CURRENT.board2-i2c-sda-pin
  bus := i2c.Bus --scl=scl --sda=sda

  devices := bus.scan

  print devices
  expect (devices.contains bme280.I2C-ADDRESS)

  device := bus.device bme280.I2C-ADDRESS
  driver := bme280.Driver device

  2.repeat:
    print driver.read-pressure
    print driver.read-humidity
    temperature := driver.read-temperature
    print temperature
    expect 12 < temperature < 35
    sleep --ms=200
