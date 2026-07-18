// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the GPIO-output HW test.

Drives EC618 GPIO11 as a square wave so the ESP32 half
(gpio-output-esp32.toit) can confirm it sees the toggles. GPIO11 is the primary
pad PAD26 (board pin 5, "uart2_txd"); the same controller bit is also exposed at
PAD22 (board pin 14), so both move together.

Wiring (NOTE: gpio.Pin numbers are PAD numbers on EC618): EC618 board pin 5 (PAD26 = GPIO11) -> ESP32 IO27.

Run via the mini-jag tester (passes when the container exits cleanly; the real
signal check happens on the ESP32 side):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 /dev/ttyUSB1 tests/hw/ec618/gpio-output-ec618.toit
*/

import gpio
import ec618 show Ec618

GPIO-EC618 ::= 11                   // Primary PAD26, wired to ESP32 IO27.
HALF-PERIOD ::= Duration --ms=50    // 10 Hz square wave.
DRIVE-DURATION ::= Duration --s=20  // Long enough for the ESP32 to sample.

main:
  pin := Ec618.gpio GPIO-EC618
  pin.configure --output --value=0
  print "gpio-output-ec618: driving GPIO$GPIO-EC618 at $(1000 / (2 * HALF-PERIOD.in-ms)) Hz for $(DRIVE-DURATION.in-s)s"
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
