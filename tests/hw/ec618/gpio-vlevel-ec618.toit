// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import ec618 show Ec618

import .wiring as wiring

/**
EC618 half of the IO-voltage characterization.

Drives GPIO10 (PAD25) HIGH and holds it, so the ESP32 half (gpio-vlevel-esp32.toit) can measure the EC618's output-high voltage on its ADC and confirm the dev-board's 3.3 V IO rail. A reading near 1.8 V is a regression.

EC618 drives, ESP32 reads -> safe regardless of the rail.
*/

HOLD ::= Duration --s=40

main:
  pin := Ec618.gpio wiring.EC618-GPIO10-NUM
  pin.configure --output --value=1
  print "gpio-vlevel-ec618: driving GPIO$(wiring.EC618-GPIO10-NUM) HIGH for $(HOLD.in-s)s (measure on the ESP32 ADC)"
  sleep HOLD
  pin.set 0
  pin.close
  print "gpio-vlevel-ec618: done"
