// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s
import .wiring show *

// No clocks are started. Exercise duplex allocation and repeated shrinking
// and growing of the rings, including compact samples and mono buffers.
main:
  with-timeout --ms=60_000:
    [false, true].do: |master/bool|
      check-capacity --master=master
  print "I2S duplex ring allocation, reconfiguration and capacity PASS"

check-capacity --master/bool:
  bus := i2s.Bus --master=master
      --tx=EC618-I2S1-TX-PAD
      --rx=EC618-I2S1-RX-PAD
      --sck=EC618-I2S1-SCK-PAD
      --ws=EC618-I2S1-WS-PAD
  try:
    buffer := ByteArray 504
    [8_000, 96_000, 16_000, 48_000, 44_100, 16_000].do: |rate/int|
      print "I2S capacity rate=$rate"
      [8, 16, 24, 32].do: |bits/int|
        if bits == 32 and rate > 48_000: continue.do
        [i2s.Bus.SLOTS-STEREO-BOTH, i2s.Bus.SLOTS-MONO-BOTH].do: |slots/int|
          bus.configure --sample-rate=rate --bits-per-sample=bits
              --slots-in=i2s.Bus.SLOTS-STEREO-BOTH
              --slots-out=slots
          frames := min (bits <= 16 ? 8192 : 4096) (max 512 (((rate + 319) / 320) * 64))
          channels := slots == i2s.Bus.SLOTS-STEREO-BOTH ? 2 : 1
          expected := frames * channels * (bits / 8)
          total := 0
          while true:
            n := bus.preload buffer
            if n == 0: break
            expect n > 0
            total += n
            expect total <= expected
          expect-equals expected total
          // Rejected configuration must leave the full old ring intact.
          error := catch: bus.configure --sample-rate=0 --bits-per-sample=bits
          expect-equals "INVALID_ARGUMENT" error
          expect-equals 0 (bus.preload buffer)
          // Unsupported rates must also preserve the configured full ring.
          [48_001, 96_000].do: |unsupported/int|
            error = catch:
              bus.configure --sample-rate=unsupported --bits-per-sample=32
            expect-equals "UNSUPPORTED" error
            error = catch:
              bus.configure --sample-rate=unsupported --bits-per-sample=32
                  --buffer-duration-ms=50
            expect-equals "UNSUPPORTED" error
            expect-equals 0 (bus.preload buffer)
    // The EC618 cannot allocate two seconds' worth of 96-kHz FIFO words
    // (1.5 MB). A failed resize must preserve the existing full TX ring.
    allocation-error := catch:
      bus.configure --sample-rate=96_000 --bits-per-sample=24
          --buffer-duration-ms=1000
    expect-equals "MALLOC_FAILED" allocation-error
    expect-equals 0 (bus.preload buffer)
    [1, 50, 200].do: |ms/int|
      bus.configure --sample-rate=16_000 --bits-per-sample=16
          --buffer-duration-ms=ms
      frames := max 512 (((16_000 * ms + 63_999) / 64_000) * 64)
      total := 0
      while true:
        n := bus.preload buffer
        if n == 0: break
        total += n
        expect total <= frames * 4
      expect-equals (frames * 4) total
      [0, -1, 1001].do: |invalid/int|
        error := catch:
          bus.configure --sample-rate=16_000 --bits-per-sample=16
              --buffer-duration-ms=invalid
        expect-equals "INVALID_ARGUMENT" error
        expect-equals 0 (bus.preload buffer)
  finally:
    bus.close
