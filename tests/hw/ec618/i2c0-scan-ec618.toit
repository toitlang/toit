// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the I2C0 bus-level HW test (device under test).

Drives real I2C0 traffic — full address scans — through pads 14 (SDA) /
13 (SCL), i.e. board pins 22/23, while the ESP32 (i2c0-wire-esp32.toit)
counts edges per wire and delivers the which-wire verdict on its console.

The bus has no devices (the wires go straight to ESP32 inputs), so the
local pass criteria are: the bus opens, every scan completes EMPTY (112
clean NACKs each — no wedge, no phantom device), and closing is clean.
This is the first real-transaction proof of the I2C0 controller; bmp280
covered I2C1 only.

Internal pull-ups both sides (--pull-up here; the ESP32 pulls its
observer pins up too) keep the open-drain bus high.

Wiring: ESP32 IO18 -> EC618 board pin 22 (I2C0_SDA / PAD14),
        ESP32 IO17 -> EC618 board pin 23 (I2C0_SCL / PAD13).

Run via the mini-jag tester AFTER the ESP32 observer is armed:

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/i2c0-scan-ec618.toit
*/

import ec618 show Ec618

SCANS ::= 3
SETTLE ::= Duration --s=2      // Give the observer's watch window time to open.

main:
  sleep SETTLE
  bus := Ec618.i2c0 --pull-up
  print "i2c0-scan-ec618: I2C0 open (SDA=PAD14, SCL=PAD13, internal pull-ups)"

  failures := []
  SCANS.repeat: | round/int |
    devices := bus.scan
    ok := devices.is-empty
    print "i2c0-scan-ec618: scan $round -> $(devices.map: "0x$(%02x it)") $(ok ? "ok (empty)" : "FAIL (phantom devices)")"
    if not ok: failures.add "scan-$(round)-phantom"
    sleep --ms=500
  bus.close
  print "i2c0-scan-ec618: bus closed"

  if failures.is-empty:
    print "i2c0-scan-ec618: PASS I2C0 scans complete cleanly on pads 14/13 (verdict on wires: see the ESP32 console)"
  else:
    print "i2c0-scan-ec618: FAIL $failures"
    throw "I2C0 scan failed: $failures"
