// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import i2s
import monitor
import ..shared.i2s-pattern
import .wiring show *

main args:
  parts := args[0].split ","
  rate := int.parse parts[0]
  bits := int.parse parts[1]
  format := int.parse parts[2]
  master := parts[3] == "master"
  slots := int.parse parts[4]
  expect-equals "duplex" parts[5]
  expect-equals 0 slots
  expect (6 <= parts.size <= 8)
  duration/int? := parts.size >= 7 and parts[6] != "default" ? (int.parse parts[6]) : null
  seconds := parts.size == 8 ? (int.parse parts[7]) : 2
  expect (1 <= seconds <= 120)
  configuration := "master=$master rate=$rate bits=$bits format=$format slots=$slots"
  if duration: configuration += " buffer_ms=$duration"
  if parts.size == 8: configuration += " capture_s=$seconds"
  data := pattern bits --inverted
  capture := ByteArray (512 * bits / 8 * 2)
  target-bytes := seconds * rate * bits / 8 * 2
  verifier := TrainingSequenceVerifier bits
  go := gpio.Pin EC618-I2S-PEER-READY-PAD --input --pull-down
  ack := gpio.Pin EC618-I2S-CAPTURE-DONE-PAD --output
  ack.set 0
  bus := i2s.Bus --master=master --tx=EC618-I2S1-TX-PAD --rx=EC618-I2S1-RX-PAD
      --sck=EC618-I2S1-SCK-PAD
      --ws=EC618-I2S1-WS-PAD
      --mclk=(master ? EC618-I2S1-MCLK-PAD : null)
  writer/Task? := null
  done := monitor.Latch
  writer-error/any := null
  started := 0
  captured := 0
  acknowledged := 0
  capture-underruns := 0
  capture-overruns := 0
  start-underruns := 0
  start-overruns := 0
  first-read-us := 0
  longest-read-us := 0
  longest-write-us := 0
  longest-read-gap-us := 0
  longest-write-gap-us := 0
  longest-verify-us := 0
  verify-us := 0
  before-verify-underruns := 0
  before-verify-overruns := 0
  last-read := 0
  last-write := 0
  reads := 0
  writes := 0
  received := 0
  completed := false
  try:
    bus.configure --sample-rate=rate --bits-per-sample=bits --format=format
        --buffer-duration-ms=duration
    training := ByteArray (TRAINING-FRAMES * bits / 8 * 2)
    expect-equals training.size (bus.preload training)
    offset := 0
    while true:
      n := bus.preload data[offset..]
      if n == 0: break
      offset = (offset + n) % data.size
    if not master: bus.start
    print "I2S DUPLEX READY $configuration"
    with-timeout --ms=(seconds * 1000 + 10_000):
      go.wait-for 1
      started = Time.monotonic-us
      if master: bus.start
      start-underruns = bus.errors --underrun
      start-overruns = bus.errors --overrun
      writer = task::
        try:
          writer-error = catch:
            if offset != 0: bus.write data[offset..]
            since-yield := 0
            while true:
              before := Time.monotonic-us
              if last-write != 0:
                longest-write-gap-us = max longest-write-gap-us (before - last-write)
              bus.write data
              last-write = Time.monotonic-us
              longest-write-us = max longest-write-us (last-write - before)
              writes++
              // Match the reader's service quantum in bytes, retaining
              // the remainder because a pattern is not a full read chunk.
              since-yield += data.size
              if since-yield >= capture.size:
                since-yield -= capture.size
                yield
        finally:
          critical-do --no-respect-deadline: done.set true
      while received < target-bytes:
        wanted := min capture.size (target-bytes - received)
        filled := 0
        while filled < wanted:
          before := Time.monotonic-us
          if last-read != 0:
            longest-read-gap-us = max longest-read-gap-us (before - last-read)
          n/int := bus.read capture[filled..wanted]
          last-read = Time.monotonic-us
          if reads == 0: first-read-us = last-read - started
          longest-read-us = max longest-read-us (last-read - before)
          reads++
          expect n > 0
          filled += n
        received += filled
        before-verify-underruns = bus.errors --underrun
        before-verify-overruns = bus.errors --overrun
        if before-verify-underruns != 0 or before-verify-overruns != 0:
          // Freeze the first observed loss before exception formatting can
          // delay servicing the rings and inflate both counters and timings.
          bus.stop
          throw "I2S underrun or overrun before payload verification"
        before-verify := Time.monotonic-us
        try:
          verifier.accept capture filled
        finally:
          elapsed := Time.monotonic-us - before-verify
          verify-us += elapsed
          longest-verify-us = max longest-verify-us elapsed
        // Reads can keep succeeding without blocking. Give the duplex
        // writer an explicit scheduling opportunity after every chunk.
        yield
      captured = Time.monotonic-us
      capture-underruns = bus.errors --underrun
      capture-overruns = bus.errors --overrun
      ack.set 1
      // The S3 lowers GO only when both captures are complete.
      go.wait-for 0
      acknowledged = Time.monotonic-us
    underruns := bus.errors --underrun
    overruns := bus.errors --overrun
    writer.cancel
    with-timeout --ms=2000: done.get
    writer = null
    bus.stop
    stopped := Time.monotonic-us
    print "DUPLEX EC SERVICE start_underruns=$start-underruns start_overruns=$start-overruns first_read_us=$first-read-us longest_read_us=$longest-read-us longest_write_us=$longest-write-us reads=$reads writes=$writes"
    print "DUPLEX EC TIMING capture_us=$(captured - started) handshake_us=$(acknowledged - captured) stop_us=$(stopped - acknowledged) capture_underruns=$capture-underruns capture_overruns=$capture-overruns"
    print "DUPLEX EC CAPTURE bytes=$target-bytes underruns=$underruns overruns=$overruns writer_error=$writer-error"
    expect-equals null writer-error
    verifier.finish
    print "DUPLEX EC VERIFIED training=$verifier.training-frames payload=$verifier.checked-bytes"
    expect-equals 0 underruns
    expect-equals 0 overruns
    print "I2S DUPLEX PASS $configuration errors=0"
    completed = true
  finally:
    try:
      if not completed:
        // Diagnostic serial output must not create additional DMA losses.
        bus.stop
        // Snapshot before cancellation/cleanup; do not replace the failure
        // if the diagnostic itself cannot inspect an already closed bus.
        catch:
          underruns := bus.errors --underrun
          overruns := bus.errors --overrun
          print "DUPLEX EC ABORT received=$received target=$target-bytes captured_us=$captured acknowledged_us=$acknowledged underruns=$underruns overruns=$overruns capture_underruns=$capture-underruns capture_overruns=$capture-overruns longest_read_us=$longest-read-us longest_write_us=$longest-write-us writes=$writes writer_error=$writer-error"
      if writer:
        writer.cancel
        with-timeout --ms=2000: done.get
    finally:
      bus.close
      ack.close
      go.close
      print "DUPLEX EC WORKLOAD verify_us=$verify-us longest_verify_us=$longest-verify-us longest_read_gap_us=$longest-read-gap-us longest_write_gap_us=$longest-write-gap-us verified_payload=$verifier.checked-bytes"
      print "DUPLEX EC BEFORE VERIFY underruns=$before-verify-underruns overruns=$before-verify-overruns"
