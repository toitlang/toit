// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import i2s
import monitor

import .wiring show *

// EC618 drives clocks. Disconnect DS18B20 DQ and keep the S3 clock/TX-peer
// pins as inputs. RX contents are immaterial; this checks active DMA lifetime.
main:
  with-timeout --ms=30_000:
    buffer := ByteArray 32768
    ["stop", "restart", "close", "cancel"].do: |mode/string|
      5.repeat: test-live-stop mode buffer
  print "I2S live-clock duplex stop, restart, close and cancellation PASS"

test-live-stop mode/string buffer/ByteArray:
  bus := i2s.Bus --master
      --tx=EC618-I2S1-TX-PAD
      --rx=EC618-I2S1-RX-PAD
      --sck=EC618-I2S1-SCK-PAD
      --ws=EC618-I2S1-WS-PAD
  writer/Task? := null
  reader/Task? := null
  writer-done := monitor.Latch
  writer-started := monitor.Latch
  reader-done := monitor.Latch
  received := monitor.Latch
  result/any := null
  reader-result/any := null
  try:
    // Small rings force a long write to block while live DMA consumes it.
    // This is a lifecycle test, not a lossless-streaming qualification.
    bus.configure --sample-rate=16_000 --bits-per-sample=16
        --buffer-duration-ms=1
    expect (bus.preload buffer) > 0
    bus.start
    reader = task::
      try:
        discard := ByteArray 256
        reader-result = catch:
          while true:
            expect (bus.read discard) > 0
            if not received.has-value: received.set true
      finally:
        critical-do --no-respect-deadline: reader-done.set true
    writer = task::
      try:
        writer-started.set true
        result = catch: bus.write buffer
      finally:
        critical-do --no-respect-deadline: writer-done.set true
    with-timeout --ms=1000:
      writer-started.get
      received.get
    sleep --ms=10
    expect (not writer-done.has-value)
    expect (not reader-done.has-value)
    // Retire the reader before restarting so it cannot issue a new read in
    // the new run. For stop/close, verify its error as well as the writer's.
    if mode == "restart" or mode == "cancel":
      reader.cancel
      with-timeout --ms=500: reader-done.get
    if mode == "cancel":
      writer.cancel
    else if mode == "close":
      bus.close
    else:
      bus.stop
      if mode == "restart": bus.start
    with-timeout --ms=500: writer-done.get
    if mode != "cancel":
      expect-equals (mode == "close" ? "CLOSED" : "INVALID_STATE") result
    if mode == "stop" or mode == "close":
      with-timeout --ms=500: reader-done.get
      expect-equals (mode == "close" ? "CLOSED" : "INVALID_STATE") reader-result
    if mode == "cancel" or mode == "restart":
      with-timeout --ms=1000:
        expect-equals 256 (bus.write (ByteArray 256))
        expect (bus.read (ByteArray 256)) > 0
  finally:
    if writer: writer.cancel
    if reader: reader.cancel
    bus.close
