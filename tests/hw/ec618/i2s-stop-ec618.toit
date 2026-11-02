// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s

import .wiring show *
import ..shared.i2s-stop show check-stop

// No external clock source may be active. PAD19/20 are inputs, so the
// DS18B20 may remain connected. S3 GPIO8, connected to TX PAD22, must be input.
main:
  with-timeout --ms=30_000:
    ["stop", "restart", "close"].do: |mode/string|
      5.repeat:
        test-stop mode
  print "I2S blocked read/write stop, immediate restart and close PASS"

test-stop mode/string:
  bus := i2s.Bus --no-master
      --tx=EC618-I2S1-TX-PAD
      --rx=EC618-I2S1-RX-PAD
      --sck=EC618-I2S1-SCK-PAD
      --ws=EC618-I2S1-WS-PAD
  try:
    bus.configure --sample-rate=16_000 --bits-per-sample=16
    // Fill the software ring, then fill the space freed into the two DMA
    // blocks at start. Neither DMA channel can progress without clocks.
    buffer := ByteArray 2048
    preloaded := 0
    while true:
      n := bus.preload buffer
      if n == 0: break
      preloaded += n
    // 200 ms at 16 kHz, two 16-bit samples per frame.
    expect-equals 12800 preloaded
    bus.start
    // Start consumes two 64-frame DMA blocks and one primed FIFO frame.
    expect-equals 516 (bus.write (ByteArray 516))
    check-stop bus mode --restart-clears-tx
  finally:
    bus.close
