// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the $gpio.Pin.wait-for functionality.

Run `wait-for-board1.toit` on board1.
Once that one is running, run `wait-for-board2.toit` on board2.
*/

import gpio

import .variants

PIN-IN ::= Variant.CURRENT.connected-pin1
PIN-OUT ::= Variant.CURRENT.connected-pin2

ITERATIONS ::= 10_000
MEDIUM-PULSE-ITERATIONS ::= 50
SHORT-PULSE-ITERATIONS ::= 50
ULTRA-SHORT-PULSE-ITERATIONS ::= 50
