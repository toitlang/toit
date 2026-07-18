// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Generates the waveform for the paired RMT resource-lifecycle test.

import gpio
import rmt

import .test
import .variants

PIN ::= Variant.CURRENT.board-connection-pin5
CLK-DIV ::= 4
BURSTS ::= 750

main:
  run-test: test

test:
  pin := gpio.Pin PIN
  out := rmt.Channel --output pin --clk-div=CLK-DIV --idle-level=1  // @no-warn
  signals := rmt.Signals.alternating 20 --first-level=1: | index/int |
    index % 2 == 0 ? 25 : 30  // 1.25 us high, 1.50 us low.

  // Board 1 starts before board 2. Give the receiver time to start waiting.
  sleep --ms=2_000
  BURSTS.repeat: | index/int |
    out.write signals
    sleep --ms=10
    if index % 250 == 249:
      print "RMT stability generator: $(index + 1) bursts"

  out.close
  pin.close
