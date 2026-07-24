// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import pulse-counter

/**
ESP32 half of the I2C0 bus-level HW test: hardware pulse counters watch
  both I2C0 wires while the EC618 (i2c0-scan-ec618.toit) drives scan
  traffic on pads 14 (SDA) / 13 (SCL).

Two things are proven at once (per docs/ec618-hw-tests.md, the coverage
  matrix): the I2C0 controller really drives board pins 22/23, and — for
  the first time — WHICH wire is which: the two pins have only ever moved
  in lockstep. During an address scan SCL carries ~18 edges per 9-bit
  frame while SDA carries a handful, so the expected-SCL wire (IO17) must
  count clearly more edges than the expected-SDA wire (IO18). A swapped
  pair inverts the ratio and fails — with counts that say so.

The I2C clock (~46 kHz on the EC618) is far too fast for GPIO polling;
  the ESP32's pulse-counter peripheral counts in hardware (the pwm test's
  trick). Internal pull-ups on both observer pins keep the open-drain bus
  high alongside the EC618's own pad pull-ups.

Wiring: ESP32 IO18 -> EC618 board pin 22 (I2C0_SDA / PAD14),
        ESP32 IO17 -> EC618 board pin 23 (I2C0_SCL / PAD13).

Run via Jaguar FIRST (it baselines a quiet bus, then watches), then start
  the EC618 half:

```
  jag run tests/hw/ec618/i2c0-wire-esp32.toit --device <esp32>
```
*/

PIN-SCL ::= 17                 // Expected SCL (board pin 23 / PAD13).
PIN-SDA ::= 18                 // Expected SDA (board pin 22 / PAD14).
BASELINE ::= Duration --s=3
WINDOW ::= Duration --s=25
MAX-BASELINE-EDGES ::= 20      // A pulled-up idle bus is quiet.
MIN-SCL-EDGES ::= 1500         // 3 scans x 112 frames x ~18 edges >> this.
MIN-SDA-EDGES ::= 150          // Address bits + start/stop, far fewer than SCL.

count pin-num/int window/Duration -> int:
  pin := gpio.Pin pin-num --input --pull-up
  unit := pulse-counter.Unit pin
  sleep window
  edges := unit.value
  unit.close
  pin.close
  return edges

main:
  print "i2c0-wire-esp32: baseline (quiet bus) $(BASELINE.in-s)s"
  base-scl := count PIN-SCL BASELINE
  base-sda := count PIN-SDA BASELINE
  print "i2c0-wire-esp32: baseline scl=$base-scl sda=$base-sda"

  print "i2c0-wire-esp32: watching IO$PIN-SCL (SCL?) + IO$PIN-SDA (SDA?) for $(WINDOW.in-s)s"
  // The counters watch sequentially-opened units on both pins at once.
  scl-pin := gpio.Pin PIN-SCL --input --pull-up
  sda-pin := gpio.Pin PIN-SDA --input --pull-up
  scl-unit := pulse-counter.Unit scl-pin
  sda-unit := pulse-counter.Unit sda-pin
  sleep WINDOW
  scl-edges := scl-unit.value
  sda-edges := sda-unit.value
  scl-unit.close
  sda-unit.close
  scl-pin.close
  sda-pin.close
  print "i2c0-wire-esp32: scl=$scl-edges sda=$sda-edges"

  failures := []
  if base-scl > MAX-BASELINE-EDGES or base-sda > MAX-BASELINE-EDGES:
    failures.add "noisy-baseline ($base-scl/$base-sda)"
  if scl-edges < MIN-SCL-EDGES:
    failures.add "scl-quiet (IO$PIN-SCL saw $scl-edges, wanted >= $MIN-SCL-EDGES)"
  if sda-edges < MIN-SDA-EDGES:
    failures.add "sda-quiet (IO$PIN-SDA saw $sda-edges, wanted >= $MIN-SDA-EDGES)"
  if scl-edges < 2 * sda-edges:
    failures.add "wire-identity (SCL should clock ~4x SDA; a swap inverts this: $scl-edges vs $sda-edges)"

  if failures.is-empty:
    print "i2c0-wire-esp32: PASS I2C0 drives pins 22/23; IO17=SCL IO18=SDA confirmed"
  else:
    print "i2c0-wire-esp32: FAIL $failures"
