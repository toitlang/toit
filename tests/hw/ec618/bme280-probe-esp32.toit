// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32-side BME/BMP280 probe — validates the breadboard hookup before the
EC618 I2C bring-up uses the sensor.

Powers the sensor from IO13, scans the I2C bus on the shared nets
(SDA = IO18, SCL = IO17 — the wires that also reach the EC618's I2C0
pads), reads the chip-id register (0xD0: 0x60 = BME280, 0x58 = BMP280,
0x56/0x57 = BMP280 samples) and, for a BME280, takes real measurements
via the driver package. SDO is tied to GND, so the address is 0x76.

Run via Jaguar:

  jag run tests/hw/ec618/bme280-probe-esp32.toit --device <esp32>
*/

import bme280
import gpio
import i2c

POWER ::= 13
SDA ::= 18
SCL ::= 17
ADDRESS ::= 0x76     // SDO tied to GND.
REG-CHIP-ID ::= 0xd0

main:
  power := gpio.Pin POWER --output --value=1
  sleep --ms=20  // Sensor start-up (2 ms per datasheet; generous).

  bus := i2c.Bus --sda=(gpio.Pin SDA) --scl=(gpio.Pin SCL)
  devices := bus.scan
  print "bme280-probe: scan -> $(devices.map: "0x$(%02x it)")"

  if not devices.contains ADDRESS:
    print "bme280-probe: FAIL no device at 0x$(%02x ADDRESS)"
    power.set 0
    return

  device := bus.device ADDRESS
  id := (device.registers.read-bytes REG-CHIP-ID 1)[0]
  kind/string := "unknown"
  if id == 0x60: kind = "BME280"
  else if id == 0x58: kind = "BMP280"
  else if id == 0x56 or id == 0x57: kind = "BMP280 (sample)"
  print "bme280-probe: chip-id 0x$(%02x id) -> $kind"

  if id == 0x60:
    driver := bme280.Driver device
    3.repeat:
      print "bme280-probe: T=$(%.2f driver.read-temperature)C  P=$(%.1f driver.read-pressure)Pa  H=$(%.1f driver.read-humidity)%"
      sleep --ms=200
    driver.close
  else if id == 0x58 or id == 0x56 or id == 0x57:
    print "bme280-probe: BMP280 — no humidity; driver check left to the EC618 test"

  print "bme280-probe: PASS"
  power.set 0
  print "bme280-probe: sensor powered off"
