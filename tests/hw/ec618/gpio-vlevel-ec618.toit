// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the IO-voltage characterization.

Drives GPIO10 (PAD25) HIGH and holds it, so the ESP32 half
(gpio-vlevel-esp32.toit) can measure the EC618's output-high voltage on its ADC
and tell whether the dev-board IO rail is 1.8 V or 3.3 V. (This matters for the
safe direction of dual-board tests: if the dev-board level-shifts its IO to
3.3 V, then ESP32 -> EC618 is no longer the "risky 3.3 V into 1.8 V" case.)

EC618 drives, ESP32 reads -> safe regardless of the rail.

Wiring: EC618 board pin (GPIO10 / PAD25) <-> ESP32 IO32 (ADC1) and IO14 (ADC2).

Run via the mini-jag tester (start gpio-vlevel-esp32.toit on the ESP32 first):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/gpio-vlevel-ec618.toit
*/

import gpio
import ec618 show Ec618

PAD-EC618 ::= 25                // GPIO10's primary pad, wired to ESP32 IO32 (ADC1) + IO14 (ADC2).
HOLD ::= Duration --s=40

main:
  pin := Ec618.gpio PAD-EC618
  pin.configure --output --value=1
  print "gpio-vlevel-ec618: driving GPIO$PAD-EC618 HIGH for $(HOLD.in-s)s (measure on the ESP32 ADC)"
  sleep HOLD
  pin.set 0
  pin.close
  print "gpio-vlevel-ec618: done"
