// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Repeatedly reserves every input RMT memory block, captures a waveform, and
// releases the channel. This catches resource leaks and allocator instability.

import gpio
import rmt

import .test
import .variants

PIN ::= Variant.CURRENT.board-connection-pin5
CLK-DIV ::= 4
IDLE-TICKS ::= 200
CAPTURES ::= 500

main:
  run-test: test

test:
  pin := gpio.Pin PIN
  CAPTURES.repeat: | index/int |
    channel := rmt.Channel --input pin --memory-block-count=8 --clk-div=CLK-DIV --idle-threshold=IDLE-TICKS  // @no-warn
    signals := channel.read
    channel.close

    // Allocation can begin at the final phase of board 1's burst. This test
    // stresses resource reuse rather than burst alignment.
    if signals.size == 0: throw "Empty RMT capture"
    if index % 100 == 99:
      print "RMT stability receiver: $(index + 1) captures"

  pin.close
