// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

/**
Tests the $gpio.Pin.wait-for functionality.

# Setup
You need two boards.
- Connect GND of board1 to GND of board2.
- Connect pin 22 of board1 to pin 23 of board2.
- Connect pin 23 of board1 to pin 22 of board2.

Run `wait-for-board1.toit` on board1.
Once that one is running, run `wait-for-board2.toit` on board2.
*/

PIN-IN ::= 22
PIN-OUT ::= 23

ITERATIONS ::= 10_000
MEDIUM-PULSE-ITERATIONS ::= 50
SHORT-PULSE-ITERATIONS ::= 50
ULTRA-SHORT-PULSE-ITERATIONS ::= 50
