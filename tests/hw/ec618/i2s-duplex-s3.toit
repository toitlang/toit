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

main:
  console := uart.Port.console
  go := gpio.Pin S3-I2S-PEER-READY-PIN --output
  go.set 0
  ack := gpio.Pin S3-I2S-CAPTURE-DONE-PIN --input --pull-down
  peer/Peer? := null
  configuration/string? := null
  try:
    while line := console.in.read-line:
      parts := line.split " "
      if parts[0] == "PING":
        print "BUS-REPLY READY"
      else if parts[0] == "IDENTIFY":
        print "BUS-REPLY EC618-I2S-DUPLEX-v1"
      else if parts[0] == "PREPARE" or parts[0] == "START":
        requested := parts[1..].join " "
        if configuration and configuration != requested: throw "INVALID_ARGUMENT"
        if not peer:
          peer = Peer parts go ack
          configuration = requested
        if parts[0] == "START": peer.start
        print "BUS-REPLY READY"
      else if parts[0] == "RESULT":
        if not peer: throw "INVALID_STATE"
        error := catch: peer.report
        if error: print "BUS-REPLY FAILED $error"
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
    ack.close
    go.close

class Peer:
  bus_/i2s.Bus
  go_/gpio.Pin
  ack_/gpio.Pin
  data_/ByteArray
  capture_/ByteArray
  target-bytes_/int
  received_/int := 0
  offset_/int := 0
  verifier_/TrainingSequenceVerifier
  identity_/string
  tasks_ := []
  latches_ := []
  started_ := monitor.Latch
  checked_ := false
  failure_/any := null
  underruns_ := 0
  overruns_ := 0
  before-verify-underruns_ := 0
  before-verify-overruns_ := 0
  start-us_ := 0
  first-write-us_ := 0
  first-read-us_ := 0
  last-write-us_ := 0
  last-read-us_ := 0
  longest-write-us_ := 0
  longest-read-us_ := 0
  longest-write-gap-us_ := 0
  longest-read-gap-us_ := 0
  writes_ := 0
  reads_ := 0
  written_ := 0
  preloaded_ := 0

  constructor parts/List .go_ .ack_:
    rate := int.parse parts[1]
    bits := int.parse parts[2]
    format := int.parse parts[3]
    master := parts[4] == "master"
    expect-equals "0" parts[5]
    expect-equals "duplex" parts[6]
    expect (parts.size == 7 or parts.size == 8)
    seconds := parts.size == 8 ? (int.parse parts[7]) : 2
    expect (1 <= seconds <= 10)
    identity_ = "$rate $bits $format 0 duplex"
    if parts.size == 8: identity_ += " capture_s=$seconds"
    data_ = pattern bits
    capture_ = ByteArray (512 * bits / 8 * 2)
    target-bytes_ = seconds * rate * bits / 8 * 2
    verifier_ = TrainingSequenceVerifier bits --inverted --allow-partial-first
        --startup-extra=(master ? 1 : 0)
    bus_ = i2s.Bus --master=master --tx=S3-I2S1-TX-PIN --rx=S3-I2S1-RX-PIN
        --sck=S3-I2S1-SCK-PIN
        --ws=S3-I2S1-WS-PIN
    configured := false
    try:
      bus_.configure --sample-rate=rate --bits-per-sample=bits --format=format
      training := ByteArray (TRAINING-FRAMES * bits / 8 * 2)
      expect-equals training.size (bus_.preload training)
      preloaded_ = training.size
      while true:
        n := bus_.preload data_[offset_..]
        if n == 0: break
        preloaded_ += n
        offset_ = (offset_ + n) % data_.size
      configured = true
    finally:
      if not configured: bus_.close

  start:
    if not tasks_.is-empty: throw "INVALID_STATE"
    // Create both workers before any clock can consume the preload. In slave
    // mode GO releases the EC master; it must not precede worker creation.
    writer-done := monitor.Latch
    latches_.add writer-done
    tasks_.add (task::
      try:
        error := catch:
          started_.get
          if offset_ != 0: write_ data_[offset_..]
          while true: write_ data_
        if error: failure_ = error
      finally:
        critical-do --no-respect-deadline: writer-done.set true)
    reader-done := monitor.Latch
    discard := ByteArray 504
    latches_.add reader-done
    tasks_.add (task::
      try:
        error := catch:
          started_.get
          with-timeout --ms=20_000:
            while received_ < target-bytes_:
              before := Time.monotonic-us
              if last-read-us_ != 0:
                longest-read-gap-us_ = max longest-read-gap-us_ (before - last-read-us_)
              n/int := bus_.read capture_[..min capture_.size (target-bytes_ - received_)]
              last-read-us_ = Time.monotonic-us
              if reads_ == 0: first-read-us_ = last-read-us_ - start-us_
              longest-read-us_ = max longest-read-us_ (last-read-us_ - before)
              reads_++
              if n <= 0: throw "Empty I2S read"
              before-verify-underruns_ = bus_.errors --underrun
              before-verify-overruns_ = bus_.errors --overrun
              verifier_.accept capture_ n
              received_ += n
              // A continuously ready reader must not starve the writer.
              yield
            underruns_ = bus_.errors --underrun
            overruns_ = bus_.errors --overrun
            checked_ = true
            ack_.wait-for 1
            go_.set 0
          while true: bus_.read discard
        if error:
          underruns_ = bus_.errors --underrun
          overruns_ = bus_.errors --overrun
          failure_ = error
      finally:
        critical-do --no-respect-deadline: reader-done.set true)
    start-us_ = Time.monotonic-us
    bus_.start
    started_.set true
    // Let the ready workers reach their I/O waits before signaling the EC.
    yield
    go_.set 1

  write_ data/ByteArray:
    before := Time.monotonic-us
    if last-write-us_ != 0:
      longest-write-gap-us_ = max longest-write-gap-us_ (before - last-write-us_)
    bus_.write data
    last-write-us_ = Time.monotonic-us
    if writes_ == 0: first-write-us_ = last-write-us_ - start-us_
    longest-write-us_ = max longest-write-us_ (last-write-us_ - before)
    writes_++
    written_ += data.size

  report:
    // Before completion these fields have not been sampled yet. Report live
    // counters rather than misleading initialized zeros on an early failure.
    if not checked_ and not failure_:
      underruns_ = bus_.errors --underrun
      overruns_ = bus_.errors --overrun
    print "DUPLEX S3 CAPTURE bytes=$received_ target=$target-bytes_ underruns=$underruns_ overruns=$overruns_"
    print "DUPLEX S3 SERVICE preloaded=$preloaded_ written=$written_ writes=$writes_ reads=$reads_ first_write_us=$first-write-us_ first_read_us=$first-read-us_ longest_write_us=$longest-write-us_ longest_read_us=$longest-read-us_ longest_write_gap_us=$longest-write-gap-us_ longest_read_gap_us=$longest-read-gap-us_"
    print "DUPLEX S3 BEFORE VERIFY underruns=$before-verify-underruns_ overruns=$before-verify-overruns_"
    if failure_:
      print "DUPLEX S3 FAILURE training=$verifier_.training-frames payload=$verifier_.checked-bytes current_buffer=$(capture_[..min 64 capture_.size])"
    if failure_: throw failure_
    if not checked_: throw "Incomplete capture"
    if underruns_ != 0 or overruns_ != 0: throw "S3 I2S data loss"
    verifier_.finish
    print "DUPLEX S3 VERIFIED training=$verifier_.training-frames payload=$verifier_.checked-bytes"
    print "BUS-REPLY VERIFIED $identity_"

  close:
    try:
      tasks_.do: it.cancel
      with-timeout --ms=2000:
        latches_.do: it.get
    finally:
      bus_.close
