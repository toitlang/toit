// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the GPIO pull-up/down HW test.

Holds IO27 high-impedance (input, no pull) so the EC618's own weak pull is the
only thing setting the shared line, and never drives it — the EC618 pad is
1.8 V, so we must not push 3.3 V into it. As a bonus cross-check it samples the
line and reports whether it saw both a high and a low level while the EC618 half
(gpio-pull-ec618.toit) sweeps pull-up then pull-down.

Wiring: EC618 board pin 5 (GPIO11 / PAD26) <-> ESP32 IO27.

Run via Jaguar (output goes to the serial console), BEFORE the EC618 half:

  jag run tests/hw/ec618/gpio-pull-esp32.toit --device <esp32>
*/

import gpio

PIN-ESP32 ::= 27
HOLD ::= Duration --s=45

main:
  // Input, NO pull: pure high-Z. The EC618's pull (tens of kΩ) dominates and we
  // never drive the line.
  pin := gpio.Pin PIN-ESP32 --input
  print "gpio-pull-esp32: IO$PIN-ESP32 held high-Z for $(HOLD.in-s)s; observing the level"
  deadline := Time.monotonic-us + HOLD.in-us
  saw-high := false
  saw-low := false
  while Time.monotonic-us < deadline:
    if pin.get == 1: saw-high = true else: saw-low = true
    sleep --ms=100
  pin.close
  // saw-high during the EC618 pull-up phase and saw-low during pull-down is the
  // expected cross-check; the authoritative verdict is on the EC618 side.
  print "gpio-pull-esp32: done (saw-high=$saw-high saw-low=$saw-low)"
