// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

/**
Oscilloscope helper: drives PAD26 (board pin 05, silk "uart2_txd";
  GPIO11 primary — the net mirrors onto board pin 14 / ESP32 IO21, and is
  wired to ESP32 IO27) as a 10 Hz square wave for 150 s, announcing
  progress on the console so the probe window is obvious.

gpio.Pin numbers are PAD numbers on EC618. 150 s stays inside the
  mini-jag per-test watchdog; rerun for more probe time.
*/

PAD ::= 26
HALF-PERIOD-MS ::= 50
SECONDS ::= 150

main:
  pin := gpio.Pin PAD --output
  print "pad26-scope: driving PAD$PAD (board pin 05) at 10 Hz for $(SECONDS)s — probe now"
  (SECONDS * 1000 / (2 * HALF-PERIOD-MS)).repeat: | i/int |
    pin.set 1
    sleep --ms=HALF-PERIOD-MS
    pin.set 0
    sleep --ms=HALF-PERIOD-MS
    if i % 100 == 99: print "pad26-scope: $(((i + 1) * 2 * HALF-PERIOD-MS) / 1000)s elapsed"
  pin.close
  print "pad26-scope: done"
