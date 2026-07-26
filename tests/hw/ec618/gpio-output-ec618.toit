// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import ec618 show Ec618

import .wiring as wiring

/**
EC618 half of the GPIO-output HW test.

Drives EC618 GPIO11 as a square wave so the ESP32 half (gpio-output-esp32.toit) can confirm it sees the toggles. GPIO11's EC618 pad is PAD26 (board pin 5, "uart2_txd"). The dev board mirrors that module net at board pin 14; this is board wiring, not a second EC618 GPIO11 pad, so `Ec618.gpio 11 --alt` must be rejected.
*/

HALF-PERIOD ::= Duration --ms=50    // 10 Hz square wave.
DRIVE-DURATION ::= Duration --s=20  // Long enough for the ESP32 to sample.

main:
  pin := Ec618.gpio wiring.EC618-GPIO11-NUM
  if pin.num != 26: throw "GPIO11 must resolve to PAD26"
  alt-error := catch: Ec618.gpio wiring.EC618-GPIO11-NUM --alt
  if alt-error == null: throw "GPIO11 must not expose the mirrored board net as an alternate pad"
  pin.configure --output --value=0
  print "gpio-output-ec618: driving GPIO$(wiring.EC618-GPIO11-NUM) at $(1000 / (2 * HALF-PERIOD.in-ms)) Hz for $(DRIVE-DURATION.in-s)s"
  deadline := Time.monotonic-us + DRIVE-DURATION.in-us
  value := 0
  toggles := 0
  while Time.monotonic-us < deadline:
    value = 1 - value
    pin.set value
    toggles++
    sleep HALF-PERIOD
  pin.set 0
  pin.close
  print "gpio-output-ec618: done ($toggles toggles)"
