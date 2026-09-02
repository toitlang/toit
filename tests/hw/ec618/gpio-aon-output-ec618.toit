// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import ec618 show Ec618
import i2c

import .wiring as wiring

/**
Regression test for AGPIOWU output voltage on the modest-affair rig.

PAD42 (GPIO22, board pin 9) drives the BMP280's VCC on this rig. For a
  usable high level, the AON IO LDO must be powered and set to 3.3 V.
  The GPIO driver does both when it opens an AON pad.

Driving pin 9 high must power the sensor so its chip-id answers over I2C.
  The test repeats this across a power toggle.

It deliberately does NOT assert "bus dead while the rail is low": with
  the I2C bus open, the BMP280 survives on parasitic supply through its
  SDA/SCL clamp diodes, and its storage caps hold the ~0.1 uA sleep
  current for many seconds, so the sensor can answer long after VCC is
  removed.

This wiring is present on modest-affair, not quirky-plenty. Standalone
  (no ESP32 helper); don't run bmp280-esp32.toit concurrently.

*/

ADDRESS ::= 0x76
REG-CHIP-ID ::= 0xd0

failures := []

check name/string condition/bool:
  if condition:
    print "gpio-aon-output: $name: ok"
  else:
    print "gpio-aon-output: $name: FAILED"
    failures.add name

read-chip-id bus/i2c.Bus -> int?:
  device := bus.device ADDRESS
  id/int? := null
  catch: id = device.registers.read-u8 REG-CHIP-ID
  device.close
  return id

main:
  power := gpio.Pin wiring.EC618-GPIO22-PAD --output --value=0

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
  bus := i2c.Bus
      --sda=wiring.EC618-I2C1-SDA-PAD
      --scl=wiring.EC618-I2C1-SCL-PAD

  2.repeat: | round/int |
    if round > 0:
      // Power-cycle between rounds: the drive must be repeatable.
      power.set 0
      sleep --ms=500
      power.set 1
      sleep --ms=500
    id := read-chip-id bus
    print "gpio-aon-output: round $round chip-id $(id ? "0x$(%02x id)" : "unreadable")"
    check "round $round: pin 9 high powers the sensor (chip-id 0x58)" (id == 0x58)

  power.set 0
  bus.close
  power.close

  if failures.is-empty:
    print "gpio-aon-output-ec618: PASS — pin 9 output drives the sensor rail"
  else:
    print "gpio-aon-output-ec618: FAIL ($failures) — check the AON LDO voltage"
    throw "gpio-aon-output: $failures"
