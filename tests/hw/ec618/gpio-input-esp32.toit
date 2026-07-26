// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .wiring as wiring

/**
ESP32 half of the GPIO-input HW test: drives a square wave for the EC618 to read.

The reverse of gpio-output. The measured EC618 IO rail is 3.3 V, so the ESP32 can drive the EC618 input directly. IMPORTANT: the EC618 side must already have PAD26 configured as INPUT before this starts, or two 3.3 V drivers fight on the wire — the runner starts the EC618 reader first and waits before launching this. This program drives IO27 as a 10 Hz square wave.
*/

HALF ::= Duration --ms=50      // 10 Hz square wave.
DURATION ::= Duration --s=45

main:
  pin := gpio.Pin wiring.ESP32-GPIO11-PIN --output
  print "gpio-input-esp32: driving IO$(wiring.ESP32-GPIO11-PIN) at $(1000 / (2 * HALF.in-ms)) Hz for $(DURATION.in-s)s"
  deadline := Time.monotonic-us + DURATION.in-us
  v := 0
  while Time.monotonic-us < deadline:
    v = 1 - v
    pin.set v
    sleep HALF
  pin.set 0
  pin.close
  print "gpio-input-esp32: done"
