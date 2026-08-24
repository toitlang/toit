// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bmx280
import expect show *
import gpio
import i2c

import .test
import .variants

main:
  run-test: test

test:
  bus := i2c.Bus
      --scl=Variant.CURRENT.board2-i2c-scl-pin
      --sda=Variant.CURRENT.board2-i2c-sda-pin

  devices := bus.scan
  print "i2c devices: $devices"

  // The board may be wired with the primary or alt I2C address.
  address/int := ?
  if devices.contains bmx280.I2C-ADDRESS:
    address = bmx280.I2C-ADDRESS
  else if devices.contains bmx280.I2C-ADDRESS-ALT:
    address = bmx280.I2C-ADDRESS-ALT
  else:
    throw "no BME280/BMP280 at 0x76 or 0x77"

  device := bus.device address
  driver := bmx280.Driver device
  print "chip-id at 0x$(%02x address): 0x$(%02x driver.chip-id)"

  2.repeat:
    print driver.read-pressure
    if driver.has-humidity:
      print driver.read-humidity
    temperature := driver.read-temperature
    print temperature
    expect 12 < temperature < 35
    sleep --ms=200
  driver.close
