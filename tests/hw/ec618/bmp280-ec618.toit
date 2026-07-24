// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bmp280
import ec618 show Ec618
import i2c
import io
import uart

/**
EC618 I2C bring-up test against a real BMP280 (device under test).

The sensor (SDO grounded -> address 0x76) hangs on the EC618's I2C1 bus
  (SDA=PAD23, SCL=PAD24 — the module's I2C1 pins, board pins 10/13; the
  module's "I2C0" board pins turned out to be unreachable); the ESP32 only
  switches its power. Checks, all on this side:

- $i2c.Bus.scan finds exactly the sensor (this exercises the probe
  primitive — scanning previously failed on the EC618);
- probing an empty address says no;
- chip-id register reads 0x58 (BMP280);
- a forced measurement: calibration registers + raw readout + the
  datasheet temperature compensation give a plausible room temperature;
- the `bmp280` package driver works on top of the same device (plausible
  temperature and pressure).

The powered-off behavior is PRINTED, not asserted: with power off the
  sensor may stay half-alive through its breakout pull-ups (back-powering).

Wiring: EC618 UART2 (PAD26 -> IO27, IO14 -> PAD25) = power-control lane;
        sensor SDA on the PAD23 <-> ESP32 IO33 net, SCL on the PAD24 <->
        IO22 net (board pins 10/13); sensor VCC from ESP32 IO13.

Run via the mini-jag tester (start bmp280-esp32.toit FIRST):

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/bmp280-ec618.toit
```
*/

SDA-PAD ::= 23
SCL-PAD ::= 24
ADDRESS ::= 0x76
EMPTY-ADDRESS ::= 0x40

REG-CALIBRATION ::= 0x88
REG-CHIP-ID ::= 0xd0
REG-CONTROL-MEAS ::= 0xf4
REG-STATUS ::= 0xf3
REG-DATA ::= 0xf7

failures := []

main:
  control := Ec618.uart2 --baud-rate=115200
  exchange control "P 1"

  bus := Ec618.i2c1  // SDA=PAD23, SCL=PAD24.

  devices := bus.scan
  print "bmp280-ec618: scan -> $(devices.map: "0x$(%02x it)")"
  check (devices.contains ADDRESS) "scan-finds-sensor"
  check (devices.size == 1) "scan-exact"
  check (not bus.test EMPTY-ADDRESS) "probe-empty-nack"

  device := bus.device ADDRESS
  registers := device.registers

  id := registers.read-u8 REG-CHIP-ID
  print "bmp280-ec618: chip-id 0x$(%02x id)"
  check (id == 0x58) "chip-id-bmp280"

  // Temperature calibration words (dig_T1..T3, little-endian at 0x88).
  calibration := registers.read-bytes REG-CALIBRATION 6
  dig-t1 := io.LITTLE-ENDIAN.uint16 calibration 0
  dig-t2 := io.LITTLE-ENDIAN.int16 calibration 2
  dig-t3 := io.LITTLE-ENDIAN.int16 calibration 4

  3.repeat: | i/int |
    // Forced measurement: osrs_t=1, osrs_p=1, mode=forced.
    registers.write-u8 REG-CONTROL-MEAS 0b001_001_01
    sleep --ms=20
    check ((registers.read-u8 REG-STATUS) & 0b1000 == 0) "measuring-done-$i"

    // Burst read pressure + temperature (exercises multi-byte reads).
    data := registers.read-bytes REG-DATA 6
    adc-t := (data[3] << 12) | (data[4] << 4) | (data[5] >> 4)
    adc-p := (data[0] << 12) | (data[1] << 4) | (data[2] >> 4)

    // Datasheet integer compensation (yields 0.01 degC steps).
    var1 := (((adc-t >> 3) - (dig-t1 << 1)) * dig-t2) >> 11
    var2 := ((((adc-t >> 4) - dig-t1) * ((adc-t >> 4) - dig-t1)) >> 12) * dig-t3 >> 14
    t-fine := var1 + var2
    temperature := ((t-fine * 5 + 128) >> 8) / 100.0

    print "bmp280-ec618: measurement $i: T=$(%.2f temperature)C (raw T=$adc-t P=$adc-p)"
    check (5.0 < temperature and temperature < 45.0) "temperature-plausible-$i"
    sleep --ms=100

  // The same sensor through the bmp280 package driver.
  driver := bmp280.Bmp280 device
  driver.on
  temperature := driver.read-temperature
  pressure := driver.read-pressure
  print "bmp280-ec618: package driver: T=$(%.2f temperature)C P=$(%.1f pressure)Pa"
  check (5.0 < temperature and temperature < 45.0) "package-temperature"
  check (80000.0 < pressure and pressure < 110000.0) "package-pressure"

  // Power off: print what the bus sees, but don't assert — back-powering
  // through the breakout pull-ups can keep the sensor half-alive.
  exchange control "P 0"
  sleep --ms=100
  off-devices := bus.scan
  print "bmp280-ec618: powered-off scan -> $(off-devices.map: "0x$(%02x it)") (informational)"

  bus.close
  control.out.write "Q\n"
  control.close

  if not failures.is-empty:
    print "bmp280-ec618: FAIL $failures"
    throw "BMP280 I2C test failed: $failures"
  print "bmp280-ec618: PASS"

check ok/bool label/string -> none:
  print "bmp280-ec618: $label $(ok ? "ok" : "FAIL")"
  if not ok: failures.add label

// Sends a command and reads one newline-terminated reply.
exchange control/uart.Port command/string -> string:
  control.out.write "$command\n"
  buffer := #[]
  with-timeout --ms=10_000:
    while true:
      nl := buffer.index-of '\n'
      if nl >= 0: return buffer[..nl].to-string.trim
      chunk := control.in.read
      if chunk == null: throw "control lane closed"
      buffer += chunk
  unreachable
