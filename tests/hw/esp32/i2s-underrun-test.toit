// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s

import .test
import .variants

SAMPLE-RATE ::= 10_000
SAMPLE-SIZE ::= 16
MARKER-SIZE ::= 960
CAPTURE-SIZE ::= 20_000

main:
  run-test:
    output := i2s.Bus
        --master=false
        --tx=Variant.CURRENT.i2s-data1
        --sck=Variant.CURRENT.i2s-clk1
        --ws=Variant.CURRENT.i2s-ws1
    input := i2s.Bus
        --master
        --rx=Variant.CURRENT.i2s-data2
        --sck=Variant.CURRENT.i2s-clk2
        --ws=Variant.CURRENT.i2s-ws2

    try:
      output.configure
          --sample-rate=SAMPLE-RATE
          --bits-per-sample=SAMPLE-SIZE
          --format=i2s.Bus.FORMAT-PCM-SHORT
      input.configure
          --sample-rate=SAMPLE-RATE
          --bits-per-sample=SAMPLE-SIZE
          --format=i2s.Bus.FORMAT-PCM-SHORT

      // One default ESP-IDF DMA descriptor. If transmitted descriptors are
      //   not cleared before they cycle through the DMA ring, this marker
      //   repeats and is counted several times in the capture below.
      marker := ByteArray MARKER-SIZE: 0xff
      expect-equals marker.size (output.preload marker)

      output.start
      input.start

      buffer := ByteArray 2_048
      received := 0
      nonzero := 0
      while received < CAPTURE-SIZE:
        count := input.read buffer
        remaining := CAPTURE-SIZE - received
        if count > remaining: count = remaining
        count.repeat:
          if buffer[it] != 0: nonzero++
        received += count

      while (output.errors --underrun) == 0:
        sleep --ms=10

      // Classic ESP32 can lose the first stereo frame while the master and
      //   slave start. The upper bound is what detects stale DMA replay.
      expect nonzero >= MARKER-SIZE - 4
      expect nonzero <= MARKER-SIZE
      expect-equals 0 (input.errors --overrun)
    finally:
      output.close
      input.close
