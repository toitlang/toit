// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s
import gpio
import system
import ..shared.i2s-pattern
import .wiring show *

main args:
  parts := args[0].split ","
  rate := int.parse parts[0]
  bits := int.parse parts[1]
  format := int.parse parts[2]
  // Optional fourth field selects EC618-generated BCLK/WS and MCLK.
  // Both modes require DS18B20 DQ to be disconnected before the test.
  if parts.size > 3 and parts[3] != "master" and parts[3] != "slave":
    throw "INVALID_ARGUMENT"
  master := parts.size > 3 and parts[3] == "master"
  slots-in := parts.size > 4 ? (int.parse parts[4]) : i2s.Bus.SLOTS-STEREO-BOTH
  verifier := TrainingSequenceVerifier bits --slots=slots-in
  // Capture first, then inspect the sequence. Pattern searching and temporary
  // comparison slices must not consume the small hardware ring's headroom.
  buffers := List 64: ByteArray 504
  counts := List 64: 0
  read-starts := List 64: 0
  read-ends := List 64: 0
  read-gcs := List 64: 0
  bus := i2s.Bus --master=master --rx=EC618-I2S1-RX-PAD
      --sck=EC618-I2S1-SCK-PAD
      --ws=EC618-I2S1-WS-PAD
      --mclk=(master ? EC618-I2S1-MCLK-PAD : null)
  go/gpio.Pin? := null
  try:
    if master: go = gpio.Pin EC618-I2S-PEER-READY-PAD --input --pull-down
    bus.configure --sample-rate=rate --bits-per-sample=bits --format=format
        --slots-in=slots-in
        --slots-out=i2s.Bus.SLOTS-STEREO-BOTH
    // Print before starting the master so serial output cannot consume the
    // receive ring's headroom. In slave mode the S3 waits for READY to start.
    gc-before := system.gc-count
    started-us := Time.monotonic-us
    if not master: bus.start
    print "I2S RX READY master=$master rate=$rate bits=$bits format=$format slots=$slots-in"
    with-timeout --ms=10_000:
      if master:
        // The S3 raises GPIO40 only after its slave is running. Both sides
        // have configured their pins before either can consume clock edges.
        go.wait-for 1
        bus.start
      64.repeat: |index/int|
        read-starts[index] = Time.monotonic-us - started-us
        count/int := bus.read buffers[index]
        read-ends[index] = Time.monotonic-us - started-us
        read-gcs[index] = system.gc-count - gc-before
        expect count > 0
        counts[index] = count
    overruns := bus.errors --overrun
    bus.stop
    elapsed-us := Time.monotonic-us - started-us
    gc-delta := system.gc-count - gc-before
    captured := 0
    counts.do: captured += it
    print "I2S RX CAPTURE bytes=$captured overruns=$overruns gcs=$gc-delta elapsed_us=$elapsed-us"
    // Print only after stopping. Include the initial wait and every slow read
    // or collection boundary without adding serial traffic to the capture.
    64.repeat: |index/int|
      previous-end := index == 0 ? 0 : read-ends[index - 1]
      previous-gcs := index == 0 ? 0 : read-gcs[index - 1]
      delay-us := read-starts[index] - previous-end
      read-us := read-ends[index] - read-starts[index]
      if index == 0 or delay-us >= 10_000 or read-us >= 10_000 or read-gcs[index] != previous-gcs:
        print "I2S RX TIMING index=$index delay_us=$delay-us read_us=$read-us bytes=$(counts[index]) gcs=$(read-gcs[index])"
    expect-equals 0 overruns
    error := catch:
      64.repeat: |index/int| verifier.accept buffers[index] counts[index]
      verifier.finish
    if error:
      print "I2S RX HEAD $(buffers[0][..min counts[0]64])"
      print "I2S RX TRAINING frames=$verifier.training-frames"
      throw error
    print "I2S RX TRAINING frames=$verifier.training-frames"
    print "I2S RX PASS master=$master rate=$rate bits=$bits format=$format slots=$slots-in bytes=$verifier.checked-bytes overruns=0"
  finally:
    bus.close
    if go: go.close
