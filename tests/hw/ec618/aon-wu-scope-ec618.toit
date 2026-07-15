// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Oscilloscope target for docs/ec618-known-issues.md #5 (AGPIOWU output).

Drives, for ~150 s (the mini-jag watchdog allows 3 min):

- PAD42 (GPIO22, board pin 9) — the GATED pad — as a 100 Hz square wave
  through the normal GPIO output path;
- PAD44 (GPIO24, board pin 18) — a known-good AON output on the same
  LDO — as a 50 Hz square wave, as the amplitude/edge reference.

Probe board pin 9 vs pin 18 (rig ground). Readings and what they mean:

- pin 9 flat (no wave at all): the gate is a config-level block — the
  weak-driver theory dies, and the cold-boot ordering variant is next.
- pin 9 waves but low/degraded (the SDK example measured ~2.0 V on
  loaded WU pads; this net carries the BMP280 VCC + pull-ups): weak
  output cell confirmed — document as a hardware property.
- pin 9 clean full-swing like pin 18: the output works and the
  sensor-based repro was misleading (sensor inrush/undervolt) — rewire
  the verdict, close #5.

No pokes, no ESP32 helper — pure current-boot driver state.

Run when the probe is on (rerun to retrigger):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/aon-wu-scope-ec618.toit
*/

import gpio

WU-PAD ::= 42    // Board pin 9 — the gated pad, 100 Hz.
REF-PAD ::= 44   // Board pin 18 — the reference, 50 Hz.
DURATION ::= Duration --s=150

main:
  wu := gpio.Pin WU-PAD --output --value=0
  ref := gpio.Pin REF-PAD --output --value=0
  print "aon-wu-scope: pin 9 (PAD42) = 100 Hz, pin 18 (PAD44) = 50 Hz, for $(DURATION.in-s)s"

  deadline := Time.monotonic-us + DURATION.in-us
  task::
    v := 0
    while Time.monotonic-us < deadline:
      v = 1 - v
      wu.set v
      sleep --ms=5      // 100 Hz.
    wu.set 0
  v := 0
  while Time.monotonic-us < deadline:
    v = 1 - v
    ref.set v
    sleep --ms=10       // 50 Hz.
  ref.set 0
  sleep --ms=100
  wu.close
  ref.close
  print "aon-wu-scope: done"
