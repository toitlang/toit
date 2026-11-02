// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import i2s
import monitor
import uart
import ..shared.i2s-pattern
import .wiring show *

// The S3's first frame may be partial; slave transmit also permits one extra
// training frame. Every subsequent payload frame is checked without resync.
// This does not qualify first-frame fidelity. Disconnect DS18B20 DQ first.
main:
  console := uart.Port.console
  go := gpio.Pin S3-I2S-PEER-READY-PIN --output
  go.set 0
  peer/Peer? := null
  configuration/string? := null
  try:
    while line := console.in.read-line:
      parts := line.split " "
      if parts[0] == "PING":
        print "BUS-REPLY READY"
      else if parts[0] == "IDENTIFY":
        print "BUS-REPLY EC618-I2S-SINK-v1"
      else if parts[0] == "PREPARE" or parts[0] == "START":
        requested := parts[1..].join " "
        if configuration and configuration != requested: throw "INVALID_ARGUMENT"
        if not peer:
          peer = Peer parts
          configuration = requested
        if parts[0] == "START":
          peer.start
          go.set 1
        print "BUS-REPLY READY"
      else if parts[0] == "RESULT":
        if not peer: throw "INVALID_STATE"
        failure := catch: peer.report
        if failure: print "BUS-REPLY FAILED $failure"
      else if parts[0] == "STOP":
        go.set 0
        if peer:
          peer.close
          peer = null
          configuration = null
        print "BUS-REPLY OK"
      else:
        throw "INVALID_ARGUMENT"
  finally:
    if peer: peer.close
    go.close

class Peer:
  bus_/i2s.Bus
  worker_/Task? := null
  done_ := monitor.Latch
  checked_ := false
  failure_/any := null
  identity_/string
  verifier_/TrainingSequenceVerifier
  buffers_ := List 768: ByteArray 504
  counts_ := List 768: 0
  overruns_ := 0

  constructor parts/List:
    rate := int.parse parts[1]
    bits := int.parse parts[2]
    format := int.parse parts[3]
    expect (["master", "slave"].contains parts[4])
    slots := int.parse parts[5]
    expect-equals "tx" parts[6]
    identity_ = "$rate $bits $format $slots tx"
    verifier_ = TrainingSequenceVerifier bits --wire-slots=slots --inverted
        --allow-partial-first
        --startup-extra=(parts[4] == "master" ? 1 : 0)
    bus_ = i2s.Bus --master=(parts[4] == "master") --rx=S3-I2S1-RX-PIN --sck=S3-I2S1-SCK-PIN --ws=S3-I2S1-WS-PIN
    ready := false
    try:
      bus_.configure --sample-rate=rate --bits-per-sample=bits --format=format
          --slots=i2s.Bus.SLOTS-STEREO-BOTH
      ready = true
    finally:
      if not ready: bus_.close

  start:
    if worker_: throw "INVALID_STATE"
    discard := ByteArray 504
    bus_.start
    worker_ = task::
      try:
        failure_ = catch:
          with-timeout --ms=20_000:
            768.repeat: |index/int|
              counts_[index] = bus_.read buffers_[index]
          overruns_ = bus_.errors --overrun
          checked_ = true
          while true: bus_.read discard
      finally:
        critical-do --no-respect-deadline: done_.set true

  report:
    print "I2S TRAINED FIRST $(buffers_[0][..48]) overruns=$overruns_"
    if failure_: throw failure_
    expect checked_
    expect-equals 0 overruns_
    768.repeat: |index/int| verifier_.accept buffers_[index] counts_[index]
    verifier_.finish
    print "I2S SUSTAINED VERIFIED training=$verifier_.training-frames initial=$verifier_.initial-frame payload_bytes=$verifier_.checked-bytes"
    print "BUS-REPLY VERIFIED $identity_"

  close:
    try:
      if worker_:
        worker_.cancel
        with-timeout --ms=2000: done_.get
    finally:
      bus_.close
