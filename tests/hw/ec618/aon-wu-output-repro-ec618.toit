// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
REPRO for docs/ec618-known-issues.md #5 — AGPIOWU output never reaches
the wire. EXPECTED TO FAIL until that issue is solved.

The rig wires one net: EC618 board pin 9 (PAD42 / GPIO22, a wakeup-capable
AON GPIO) <-> ESP32 IO13 <-> the BMP280's VCC. PAD42 as GPIO *input*
demonstrably follows this rail; this repro drives it as an output and uses
the SENSOR as the level probe:

- PAD42 low: rail down, bus pull-ups dead — the I2C dead-bus check must
  report the bus as not free (this part works).
- PAD42 high: if the output worked, the sensor would power up and the
  chip-id register would read 0x58. It currently does NOT (the rail-high
  check fails) — see the known-issue entry for everything tried.

Standalone (no ESP32 helper): make sure nothing else drives the IO13 net
(do not run bmp280-esp32.toit at the same time).

Run via the mini-jag tester:

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> \
      tests/hw/ec618/aon-power-bmp280-ec618.toit
*/

import gpio
import ec618 show Ec618
import i2c

POWER-PAD ::= 42  // GPIO22, board pin 9 — AON domain.
SDA-PAD ::= 23
SCL-PAD ::= 24
ADDRESS ::= 0x76
REG-CHIP-ID ::= 0xd0

failures := []

check name/string condition/bool:
  if condition:
    print "aon-power: $name: ok"
  else:
    print "aon-power: $name: FAILED"
    failures.add name

main:
  power := gpio.Pin POWER-PAD --output --value=0
  // Let the rail discharge through the sensor before the first probe.
  sleep --ms=500

  bus := i2c.Bus --sda=(Ec618.pad SDA-PAD) --scl=(Ec618.pad SCL-PAD)

  check "rail low: bus dead" (not (bus.test ADDRESS))

  power.set 1
  sleep --ms=500  // Rail charge + sensor startup (~2 ms, generously).
  device := bus.device ADDRESS
  id/int? := null
  catch: id = device.registers.read-u8 REG-CHIP-ID
  print "aon-power: chip-id $(id ? "0x$(%02x id)" : "unreadable")"
  check "rail high: chip-id 0x58" (id == 0x58)

  power.set 0
  sleep --ms=500
  check "rail low again: bus dead" (not (bus.test ADDRESS))

  device.close
  bus.close
  power.close

  if failures.is-empty:
    print "aon-wu-output-repro-ec618: PASS — known-issue #5 is FIXED; update the docs!"
  else:
    print "aon-wu-output-repro-ec618: FAIL ($failures) — the expected state of known-issue #5"
    throw "aon-wu-output repro: $failures"
