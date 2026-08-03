// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rmt

import .test
import .variants

RESOLUTION ::= 20_000_000
PERIOD ::= 10
PIXELS ::= 1_000

// This is the number of transitions required for a 1,000-pixel RGBW frame. The
//   odd count ensures that the transmitter finishes high, creating a final
//   falling edge before the RMT end marker.
SIGNAL-COUNT ::= PIXELS * 4 * 8 * 2 - 1
CAPTURE-SIGNAL-COUNT ::= SIGNAL-COUNT + 1
CAPTURE-BYTES ::= CAPTURE-SIGNAL-COUNT * rmt.Signals.BYTES-PER-SIGNAL
RX-MEMORY-BLOCKS ::= (CAPTURE-BYTES + rmt.BYTES-PER-MEMORY-BLOCK - 1) / rmt.BYTES-PER-MEMORY-BLOCK

test-long-dma-capture --tx-dma/bool:
  pin-in := Variant.CURRENT.rmt-pin1
  pin-out := Variant.CURRENT.rmt-pin2

  input := rmt.In
      pin-in
      --resolution=RESOLUTION
      --memory-blocks=RX-MEMORY-BLOCKS
      --dma
  output := rmt.Out
      pin-out
      --resolution=RESOLUTION
      --memory-blocks=(tx-dma ? 8 : 1)
      --dma=tx-dma
  signals := rmt.Signals.alternating SIGNAL-COUNT --first-level=1: PERIOD

  try:
    input.start-reading --min-ns=1 --max-ns=50_000
    output.write signals --done-level=0
    captured := input.wait-for-data

    expect-equals CAPTURE-SIGNAL-COUNT captured.size
    SIGNAL-COUNT.repeat:
      expect-equals PERIOD (captured.period it)
      expect-equals (1 - it % 2) (captured.level it)
    expect-equals 0 (captured.period SIGNAL-COUNT)
  finally:
    output.close
    input.close

main:
  run-test:
    if rmt.DMA-SUPPORTED:
      // First isolate RX DMA behind an ordinary RMT transmitter, then exercise
      //   TX and RX DMA together across many DMA-buffer boundaries.
      test-long-dma-capture --no-tx-dma
      test-long-dma-capture --tx-dma
