// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

/**
ESP32 half of the AON-pad GPIO-input HW test: drives both AON wires at
  distinct frequencies for the EC618 to read (and tell apart).

IO19 waves at 10 Hz, IO2 at 4 Hz. IMPORTANT: the EC618 side must already
  have PAD44/PAD47 configured as INPUTS before this starts, or two 3.3 V
  drivers fight — the runner starts the EC618 reader first.

Wiring: ESP32 IO19 -> EC618 board pin 18 (GPIO24 / PAD44),
        ESP32 IO2  -> EC618 board pin 27 (GPIO27 / PAD47).

Run via Jaguar, AFTER the EC618 reader has configured its inputs:

```
  jag run tests/hw/ec618/gpio-aon-input-esp32.toit --device <esp32>
```
*/

PIN-FAST ::= 19                // -> EC618 GPIO24 (PAD44).
PIN-SLOW ::= 2                 // -> EC618 GPIO27 (PAD47).
HALF-FAST ::= Duration --ms=50   // 10 Hz.
HALF-SLOW ::= Duration --ms=125  // 4 Hz.
DURATION ::= Duration --s=45

main:
  fast := gpio.Pin PIN-FAST --output
  slow := gpio.Pin PIN-SLOW --output
  print "gpio-aon-input-esp32: IO$PIN-FAST at 10 Hz + IO$PIN-SLOW at 4 Hz for $(DURATION.in-s)s"
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
