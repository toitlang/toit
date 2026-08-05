// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the $gpio.Pin.wait-for functionality.

Run `wait-for-board1.toit` on board1.
Once that one is running, run `wait-for-board2.toit` on board2.
*/

import gpio
import system

import .variants

PIN-IN1 ::= Variant.CURRENT.board-connection-pin1
PIN-OUT1 ::= Variant.CURRENT.board-connection-pin2
PIN-IN2 ::= Variant.CURRENT.board-connection-pin2
PIN-OUT2 ::= Variant.CURRENT.board-connection-pin1

ITERATIONS ::= 10_000
MEDIUM-PULSE-ITERATIONS ::= 50
SHORT-PULSE-ITERATIONS ::= 50
ULTRA-SHORT-PULSE-ITERATIONS ::= 50

WAIT-FOR-PROGRESS-TIMEOUT ::= "WAIT_FOR_PROGRESS_TIMEOUT"

with-peer-progress-timeout phase/string timeout-ms/int [block]:
  error := catch:
    with-timeout --ms=timeout-ms: block.call
  if error == DEADLINE-EXCEEDED-ERROR:
    print "Peer GPIO made no progress during '$phase' for $(timeout-ms)ms; pins board1-in=$PIN-IN1 board1-out=$PIN-OUT1 board2-in=$PIN-IN2 board2-out=$PIN-OUT2"
    throw WAIT-FOR-PROGRESS-TIMEOUT
  if error: throw error
