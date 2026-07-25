// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .wiring as wiring

/**
ESP32 half of the AON-pad GPIO-input HW test: drives both AON wires at
  distinct frequencies for the EC618 to read (and tell apart).

IO19 waves at 10 Hz, IO2 at 4 Hz. IMPORTANT: the EC618 side must already
  have PAD44/PAD47 configured as INPUTS before this starts, or two 3.3 V
  drivers fight — the runner starts the EC618 reader first.

Run via Jaguar, AFTER the EC618 reader has configured its inputs:

```
  jag run tests/hw/ec618/gpio-aon-input-esp32.toit --device <esp32>
```
*/

HALF-FAST ::= Duration --ms=50   // 10 Hz.
HALF-SLOW ::= Duration --ms=125  // 4 Hz.
DURATION ::= Duration --s=45

main:
  fast := gpio.Pin wiring.ESP32-GPIO24-PIN --output
  slow := gpio.Pin wiring.ESP32-GPIO27-PIN --output
  print "gpio-aon-input-esp32: IO$(wiring.ESP32-GPIO24-PIN) at 10 Hz + IO$(wiring.ESP32-GPIO27-PIN) at 4 Hz for $(DURATION.in-s)s"
  deadline := Time.monotonic-us + DURATION.in-us
  task::
    v := 0
    while Time.monotonic-us < deadline:
      v = 1 - v
      fast.set v
      sleep HALF-FAST
    fast.set 0
  v := 0
  while Time.monotonic-us < deadline:
    v = 1 - v
    slow.set v
    sleep HALF-SLOW
  slow.set 0
  // Let the fast task finish its last half-period before closing.
  sleep --ms=200
  fast.close
  slow.close
  print "gpio-aon-input-esp32: done"
