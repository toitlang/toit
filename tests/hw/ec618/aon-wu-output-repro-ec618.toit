// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import ec618 show Ec618
import i2c

/**
Regression test for docs/ec618-known-issues.md #5 (RESOLVED 2026-07-02):
  the "AGPIOWU output gate" that never was.

PAD42 (GPIO22, board pin 9) drives the BMP280's VCC on this rig. For
  weeks a configured GPIO output "never reached the wire" — the scope
  finally showed it always did, at 1.8 V: the AON IO LDO boots at
  IOVOLT_1_80V and nothing raised it, so every 3.3 V observer (ESP32
  input thresholds, the sensor's supply needs) was blind to it. The
  driver now raises the LDO to 3.3 V whenever it powers it
  (pad_aon_power_on), scope-verified full swing.

This test asserts the once-impossible part: driving pin 9 HIGH powers
  the sensor and its chip-id answers over I2C — twice, across a power
  toggle, so the drive is repeatable.

It deliberately does NOT assert "bus dead while the rail is low": with
  the I2C bus open, the BMP280 survives on parasitic supply through its
  SDA/SCL clamp diodes, and its storage caps hold the ~0.1 uA sleep
  current for many seconds — the sensor can answer long after (and even
  without) VCC. That assertion was electrically unsound; the low level
  itself is scope-verified (clean 0 V) and the ESP32-side gpio22 tests
  cover the wire digitally.

Standalone (no ESP32 helper); don't run bmp280-esp32.toit concurrently.

Run via the mini-jag tester:

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> \
      tests/hw/ec618/aon-wu-output-repro-ec618.toit
```
*/

POWER-PAD ::= 42  // GPIO22, board pin 9 — AON wakeup-pad domain.
SDA-PAD ::= 23
SCL-PAD ::= 24
ADDRESS ::= 0x76
REG-CHIP-ID ::= 0xd0

failures := []

check name/string condition/bool:
  if condition:
    print "aon-wu-output: $name: ok"
  else:
    print "aon-wu-output: $name: FAILED"
    failures.add name

read-chip-id bus/i2c.Bus -> int?:
  device := bus.device ADDRESS
  id/int? := null
  catch: id = device.registers.read-u8 REG-CHIP-ID
  device.close
  return id

main:
  power := gpio.Pin POWER-PAD --output --value=0

  // TRUE sensor reset first: rail hard-low with NO i2c bus open — an
  // idle I2C controller feeds the sensor through its SDA/SCL clamp
  // diodes, and between containers the released pin 9 carries the wake
  // pull-up, so the sensor arrives here half-powered (possibly wedged
  // from a brownout, holding the bus wires low). 10 s drains its
  // storage caps for a clean power-on-reset.
  sleep --ms=10_000

  // Power the rail BEFORE opening the bus: with the rail low the bus
  // pull-ups are dead, both wires read 0, and opening/probing a dead bus
  // exercises the driver's unstick path instead of this test's subject.
  power.set 1
  sleep --ms=500  // Rail charge + sensor startup (~2 ms, generously).
  bus := i2c.Bus --sda=(Ec618.pad SDA-PAD) --scl=(Ec618.pad SCL-PAD)

  2.repeat: | round/int |
    if round > 0:
      // Power-cycle between rounds: the drive must be repeatable.
      power.set 0
      sleep --ms=500
      power.set 1
      sleep --ms=500
    id := read-chip-id bus
    print "aon-wu-output: round $round chip-id $(id ? "0x$(%02x id)" : "unreadable")"
    check "round $round: pin 9 high powers the sensor (chip-id 0x58)" (id == 0x58)

  power.set 0
  bus.close
  power.close

  if failures.is-empty:
    print "aon-wu-output-repro-ec618: PASS — pin 9 output drives the sensor rail (#5 stays resolved)"
  else:
    print "aon-wu-output-repro-ec618: FAIL ($failures) — #5 may have regressed (LDO voltage?)"
    throw "aon-wu-output: $failures"
