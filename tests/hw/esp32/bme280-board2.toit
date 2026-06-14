// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bme280
import bmp280
import expect show *
import gpio
import i2c

import .test
import .variants

REG-CHIP-ID_    ::= 0xD0
CHIP-ID-BME280_ ::= 0x60  // Combined T/P/H sensor.
CHIP-ID-BMP280_ ::= 0x58  // T/P only.

main:
  run-test: test

test:
  scl := gpio.Pin Variant.CURRENT.board2-i2c-scl-pin
  sda := gpio.Pin Variant.CURRENT.board2-i2c-sda-pin
  bus := i2c.Bus --scl=scl --sda=sda

  devices := bus.scan
  print "i2c devices: $devices"

  // The board may be wired with the primary or alt I2C address.
  address/int := ?
  if devices.contains bme280.I2C-ADDRESS:
    address = bme280.I2C-ADDRESS
  else if devices.contains bme280.I2C-ADDRESS-ALT:
    address = bme280.I2C-ADDRESS-ALT
  else:
    throw "no BME280/BMP280 at 0x76 or 0x77"

  device := bus.device address
  chip-id := device.registers.read-u8 REG-CHIP-ID_
  print "chip-id at 0x$(%02x address): 0x$(%02x chip-id)"

  if chip-id == CHIP-ID-BME280_:
    test-bme280_ device
  else if chip-id == CHIP-ID-BMP280_:
    test-bmp280_ device
  else:
    throw "unexpected chip-id 0x$(%02x chip-id) — wanted BME280 (0x60) or BMP280 (0x58)"

test-bme280_ device/i2c.Device:
  driver := bme280.Driver device
  2.repeat:
    print driver.read-pressure
    print driver.read-humidity
    temperature := driver.read-temperature
    print temperature
    expect 12 < temperature < 35
    sleep --ms=200

test-bmp280_ device/i2c.Device:
  driver := bmp280.Bmp280 device
  driver.on
  2.repeat:
    print driver.read-pressure
    temperature := driver.read-temperature
    print temperature
    expect 12 < temperature < 35
    sleep --ms=200
  driver.off
