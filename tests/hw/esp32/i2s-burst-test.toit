// Copyright (C) 2026 Toit contributors.
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

// The receiver sometimes locks on one bit off when master and slave start,
//   and then sees every byte shifted. See
//   https://github.com/espressif/esp-idf/issues/15275.
// The writer sends a preamble before the bursts. If it doesn't arrive intact,
//   the test restarts the buses.
PREAMBLE ::= #[0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a]
MAX-STARTS ::= 3

main:
  run-test:
    starts := 1
    while not run-bursts:
      if starts == MAX-STARTS: throw "Preamble not received intact in $MAX-STARTS starts"
      print "Preamble not received intact. Restarting the buses."
      starts++

/**
Runs the test.

Returns false if the preamble didn't arrive intact, in which case the bursts
  weren't sent.
*/
run-bursts -> bool:
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
    return test-bursts --in=in --out=out
  finally:
    out.close
    in.close

test-bursts --in/i2s.Bus --out/i2s.Bus -> bool:
  bursts := []
  ROUNDS.repeat: |round|
    SIZES.size.repeat: |i|
      // Vary the order of sizes between rounds.
      size := SIZES[(i + round * 3) % SIZES.size]
      GAPS-MS.do: |gap| bursts.add [size, gap]

  // Every 4-byte frame repeats one nonzero value, so the check doesn't depend
  //   on how the receiver aligns samples. The bus emits zeros when it runs
  //   out of data, so the nonzero bytes must be exactly the bursts.
  // All sizes are multiples of 4, so the byte at position p of the stream is
  //   PATTERN[p % PERIOD]. The bursts are slices of the pattern, and the
  //   reader checks the bytes as they arrive. The ESP32 doesn't have the
  //   memory to keep the whole stream.
  period := 255 * 4
  pattern := ByteArray period + (SIZES.reduce: | a b | max a b): (it / 4) % 255 + 1
  starts := []
  total := 0
  bursts.do: |burst|
    starts.add total
    total += burst[0]

  preamble-received := 0
  preamble-intact := true
  received := 0
  mismatch/int? := null
  mismatch-actual := #[]
  stop := false
  reader-done := monitor.Latch
  in.start
  task::
    buffer := ByteArray 496
    while not stop:
      count := in.read buffer
      if not count: break
      count.repeat:
        byte := buffer[it]
        if byte == 0: continue.repeat
        if preamble-received < PREAMBLE.size:
          if byte != PREAMBLE[preamble-received]: preamble-intact = false
          preamble-received++
          continue.repeat
        if mismatch:
          if mismatch-actual.size < 16: mismatch-actual += #[byte]
        else if received >= total or byte != pattern[received % period]:
          mismatch = received
          mismatch-actual = #[byte]
        received++
    reader-done.set true

  // The classic ESP32 can lose the first stereo frame while master and slave
  //   start. Lose zeros instead.
  // Preload less than a DMA buffer. The DMA starts sending that buffer when
  //   the bus starts, so the first burst must not be appended to it.
  expect-equals 480 (out.preload (ByteArray 480))
  expect-equals PREAMBLE.size (out.preload PREAMBLE)
  out.start
  // Write the first burst after the DMA has sent the preloaded bytes (12 ms),
  //   but before it is done with their buffer (24 ms).
  sleep --ms=18

  bursts.size.repeat: |i|
    size := bursts[i][0]
    offset := starts[i] % period
    out.write pattern[offset..offset + size]
    if i == 0:
      deadline := Time.monotonic-us + 1_000_000
      while preamble-received < PREAMBLE.size and Time.monotonic-us < deadline:
        sleep --ms=10
      if preamble-received < PREAMBLE.size or not preamble-intact:
        stop = true
        reader-done.get
        return false
    gap := bursts[i][1]
    if gap > 0: sleep --ms=gap

  // Wait for the queued data, then for a while longer to catch duplicates.
  deadline := Time.monotonic-us + 2_000_000
  while received < total and not mismatch and Time.monotonic-us < deadline:
    sleep --ms=50
  sleep --ms=500
  stop = true
  reader-done.get

  if mismatch or received != total:
    print "Received $received nonzero bytes, expected $total."
  if mismatch:
    at := mismatch
    burst := 0
    while burst + 1 < starts.size and starts[burst + 1] <= at: burst++
    print "First mismatch at byte $at: burst $burst (size $bursts[burst][0], previous gap $(burst > 0 ? bursts[burst - 1][1] : 0) ms), offset $(at - starts[burst])."
    expected-end := min total at + 16
    expected := ByteArray expected-end - at: pattern[(at + it) % period]
    print "  actual:   $mismatch-actual"
    print "  expected: $expected"
  expect-null mismatch
  expect-equals total received
  expect-equals 0 (in.errors --overrun)
  print "$bursts.size bursts, $total bytes received intact"
  return true
