// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the GPIO-input HW test: drives a square wave for the EC618 to read.

The reverse of gpio-output. Now that the EC618 IO rail is 3.3 V (see
docs/ec618-hw-tests.md), the ESP32 can drive the EC618 input directly. IMPORTANT:
the EC618 side must already have PAD26 configured as INPUT before this starts, or
two 3.3 V drivers fight on the wire — the runner starts the EC618 reader first and
waits before launching this. This program drives IO27 as a 10 Hz square wave.

Wiring: ESP32 IO27 -> EC618 board pin 5 (GPIO11 / PAD26).

Run via Jaguar, AFTER the EC618 reader has set PAD26 to input:

  jag run tests/hw/ec618/gpio-input-esp32.toit --device <esp32>
*/

import gpio

PIN-ESP32 ::= 27
HALF ::= Duration --ms=50      // 10 Hz square wave.
DURATION ::= Duration --s=45

main:
  pin := gpio.Pin PIN-ESP32 --output
  print "gpio-input-esp32: driving IO$PIN-ESP32 at $(1000 / (2 * HALF.in-ms)) Hz for $(DURATION.in-s)s"
  deadline := Time.monotonic-us + DURATION.in-us
  v := 0
  while Time.monotonic-us < deadline:
    v = 1 - v
    pin.set v
    sleep HALF
  pin.set 0
  pin.close
  print "gpio-input-esp32: done"
