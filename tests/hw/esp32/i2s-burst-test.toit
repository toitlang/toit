// Copyright (C) 2026 Toit contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that bursts written with pauses in between arrive intact and in order.

When a write ends in the middle of a DMA buffer and the bus runs out of data
  before the next write, the DMA may already be sending that buffer. Data
  appended to it is then dropped, or sent a full DMA ring later.

For the setup see the documentation near $Variant.i2s-data1.
*/

import expect show *
import i2s
import io
import monitor

import .test
import .variants

SAMPLE-RATE ::= 10_000
// With 16-bit stereo samples the bus sends 40 bytes per ms. A default
//   ESP-IDF DMA buffer (960 bytes) lasts 24 ms, the ring of 6 buffers 144 ms.
SIZES ::= [4, 100, 500, 960, 1_000, 2_000, 4_000]
// Shorter than a buffer, between a buffer and the ring, longer than the ring.
GAPS-MS ::= [0, 5, 30, 100, 300]
ROUNDS ::= 3

main:
  run-test:
    out := i2s.Bus
        --master=false
        --tx=Variant.CURRENT.i2s-data1
        --sck=Variant.CURRENT.i2s-clk1
        --ws=Variant.CURRENT.i2s-ws1
    in := i2s.Bus
        --master
        --rx=Variant.CURRENT.i2s-data2
        --sck=Variant.CURRENT.i2s-clk2
        --ws=Variant.CURRENT.i2s-ws2
    try:
      out.configure --sample-rate=SAMPLE-RATE --bits-per-sample=16
      in.configure --sample-rate=SAMPLE-RATE --bits-per-sample=16
      test-bursts --in=in --out=out
    finally:
      out.close
      in.close

test-bursts --in/i2s.Bus --out/i2s.Bus:
  bursts := []
  ROUNDS.repeat: |round|
    SIZES.size.repeat: |i|
      // Vary the order of sizes between rounds.
      size := SIZES[(i + round * 3) % SIZES.size]
      GAPS-MS.do: |gap| bursts.add [size, gap]

  // Every 4-byte frame repeats one nonzero value, so the check doesn't depend
  //   on how the receiver aligns samples. The bus emits zeros when it runs
  //   out of data, so the nonzero bytes must be exactly the bursts.
  expected := io.Buffer
  starts := []
  frame := 0
  data := bursts.map: |burst|
    size := burst[0]
    starts.add expected.size
    bytes := ByteArray size: ((frame + it / 4) % 255) + 1
    frame += size / 4
    expected.write bytes
    bytes

  received := io.Buffer
  stop := false
  reader-done := monitor.Latch
  in.start
  task::
    while not stop:
      chunk := in.read
      if not chunk: break
      chunk.do: if it != 0: received.write-byte it
    reader-done.set true

  out.start
  // The classic ESP32 can lose the first stereo frame while master and slave
  //   start. Lose zeros instead.
  out.write (ByteArray 960)

  bursts.size.repeat: |i|
    out.write data[i]
    gap := bursts[i][1]
    if gap > 0: sleep --ms=gap

  // Wait for the queued data, then for a while longer to catch duplicates.
  deadline := Time.monotonic-us + 2_000_000
  while received.size < expected.size and Time.monotonic-us < deadline:
    sleep --ms=50
  sleep --ms=500
  stop = true
  reader-done.get

  actual := received.bytes
  expected-bytes := expected.bytes
  if actual != expected-bytes:
    at := 0
    while at < actual.size and at < expected-bytes.size and actual[at] == expected-bytes[at]:
      at++
    burst := 0
    while burst + 1 < starts.size and starts[burst + 1] <= at: burst++
    print "Received $actual.size nonzero bytes, expected $expected-bytes.size."
    print "First mismatch at byte $at: burst $burst (size $bursts[burst][0], previous gap $(burst > 0 ? bursts[burst - 1][1] : 0) ms), offset $(at - starts[burst])."
    end := min actual.size at + 16
    expected-end := min expected-bytes.size at + 16
    print "  actual:   $actual[at..end]"
    print "  expected: $expected-bytes[at..expected-end]"
  expect-equals expected-bytes actual
  expect-equals 0 (in.errors --overrun)
  print "$bursts.size bursts, $expected-bytes.size bytes received intact"
