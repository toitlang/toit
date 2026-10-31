// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import pulse-counter
import rmt

check-frequency number/int frequency/int:
  // Two seconds at 10 kHz stays below the PCNT's 32767-count wrap point.
  if not 4 <= frequency <= 10_000: throw "PWM frequency probe range is 4..10000 Hz"
  counter := pulse-counter.Unit number --glitch-filter-ns=100 --no-start
  try:
    start := Time.monotonic-us
    counter.start
    sleep --ms=2000
    counter.stop
    elapsed := Time.monotonic-us - start
    expect elapsed < 2_900_000
    edges := counter.value
    expected := elapsed * frequency / 1_000_000.0
    tolerance := expected * 0.03
    if tolerance < 2: tolerance = 2.0
    expect ((edges - expected).abs <= tolerance)
        --message="PWM pin=$number expected=$frequency Hz, got $edges edges in $elapsed us"
    print "RIG PWM_HZ pin=$number edges=$edges elapsed-us=$elapsed PASS"
  finally:
    counter.close

check-duty number/int permille/int:
  if not 0 <= permille <= 1000: throw "Invalid PWM duty"
  pin := gpio.Pin number --input --pull-down
  try:
    deadline := Time.monotonic-us + 2_000_000
    high := 0
    count := 0
    while Time.monotonic-us < deadline:
      high += pin.get
      count++
      if count & 0x3ff == 0: yield
    measured := high * 1000.0 / count
    expect ((measured - permille).abs < 80)
        --message="PWM pin=$number expected=$permille permille, got $measured"
    print "RIG PWM_DUTY pin=$number high=$high samples=$count permille=$measured PASS"
  finally:
    pin.close

class Capture:
  number/int
  input_/rmt.In? := null

  constructor .number:
    input_ = rmt.In number --resolution=20_000_000 --memory-blocks=2
    try:
      input_.start-reading --max-ns=1_500_000
    finally: |failed _|
      if failed: close

  close:
    if input_:
      input_.close
      input_ = null

  check-pulsing:
    signals/rmt.Signals? := null
    error := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      signals = with-timeout --ms=100: input_.wait-for-data
    // Classic ESP32 RMT can remain busy until an idle gap. A continuous train
    // may time out; static-level checks must never accept that result.
    levels := [0, 0]
    if signals:
      signals.size.repeat: |index|
        if (signals.period index) != 0: levels[signals.level index]++
    expect (error != null or (levels[0] >= 4 and levels[1] >= 4))
        --message="PWM RMT positive control pin=$number low=$(levels[0]) high=$(levels[1])"
    print "RIG PWM_TRAIN pin=$number timed-out=$(error != null) low=$(levels[0]) high=$(levels[1]) PASS"

  check-static level/int:
    // The target changes level only after the ARM acknowledgement. Require a
    // completed idle capture with at most that single transition. Continuous
    // PWM either fills the buffer or times out waiting for an idle interval.
    signals := with-timeout --ms=100: input_.wait-for-data
    count := 0
    signals.size.repeat: |index|
      if (signals.period index) != 0: count++
    samples := []
    signals.size.repeat: |index|
      if index < 16: samples.add "$(signals.level index):$(signals.ns-duration index)"
    print "RIG PWM_CAPTURE pin=$number size=$signals.size signals=$count samples=$samples"
    // A single transition into idle can return only the zero-duration end
    // marker. Completion (not timeout), the paired PWM-train control and the
    // opposite-pull GPIO check together distinguish this from a PWM train.
    expect count <= 2 --message="PWM static capture contained $count nonzero signals"
    close
    check-level number level
    print "RIG PWM_STATIC pin=$number level=$level rmt-signals=$count PASS"

check-level number/int level/int:
  if level != 0 and level != 1: throw "Invalid PWM level"
  pin := gpio.Pin number --input --pull-up=(level == 0) --pull-down=(level == 1)
  try:
    sleep --ms=10
    1000.repeat:
      expect-equals level pin.get
      if it & 0x3f == 0: yield
  finally:
    pin.close
  print "RIG PWM_LEVEL pin=$number level=$level PASS"

check-released number/int:
  // Both biases are required: a forgotten constant-low output passes a
  // pull-down-only check, while an unreleased high output passes pull-up.
  [0, 1].do: |level|
    pin := gpio.Pin number --input --pull-up=(level == 1) --pull-down=(level == 0)
    try:
      sleep --ms=10
      1000.repeat:
        expect-equals level pin.get
        if it & 0x3f == 0: yield
    finally:
      pin.close
  print "RIG PWM_RELEASE pin=$number PASS"
