// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import gpio.pwm
import pulse-counter
import rmt
import .session

/** Tests duty, frequency changes, endpoints, channel independence and reuse. */
run session/Session pin/int second-pin/int:
  3.repeat: | iteration |
    session.run-case "PWM waveform and lifecycle $iteration":
      generator/pwm.Pwm? := null
      first/pwm.PwmChannel? := null
      second/pwm.PwmChannel? := null
      try:
        if session.is-testee:
          generator = pwm.Pwm --frequency=1000 --max-frequency=10_000
          first = generator.start pin --duty-factor=0.5
          second = generator.start second-pin --duty-factor=0.25
          expect-throw "ALREADY_IN_USE": gpio.Pin pin --output
          expect-throw "OUT_OF_BOUNDS": generator.frequency = 10_001
        [1000, 2000, 10_000, 1000].do: | frequency |
          if session.is-testee: generator.frequency = frequency
          [0.25, 0.5, 0.75, 0.0, 1.0, 0.5].do: | duty |
            if session.is-testee: first.set-duty-factor duty
            measure session pin frequency duty first
          // Updating the first channel must not change the second's duty.
          measure session second-pin frequency 0.25 second
        if session.is-testee: first.close
        measure session second-pin 1000 0.25 second
      finally:
        // Closing the parent must also release the still-open second channel.
        if generator: generator.close
  [0.0, 1.0].do: | duty |
    session.run-case "PWM initial static duty=$duty":
      generator/pwm.Pwm? := null
      channel/pwm.PwmChannel? := null
      try:
        if session.is-testee:
          generator = pwm.Pwm --frequency=1000
          channel = generator.start pin --duty-factor=duty
        measure session pin 1000 duty channel
      finally:
        if generator: generator.close

measure session/Session pin/int frequency/int duty/float channel/pwm.PwmChannel?:
  if session.is-testee:
    // Allow a timer cycle for the update to take effect before observing it.
    sleep --ms=5
    expect (channel.duty-factor - duty).abs < 0.01
        --message="PWM duty readback: expected $duty, got $channel.duty-factor"
    session.send "ready"
    if duty != 0.0 and duty != 1.0:
      expect-equals "capture" session.receive
      sleep --ms=3
      channel.set-duty-factor 0.0
      session.send "stopped"
      expect-equals "resume" session.receive
      channel.set-duty-factor duty
      sleep --ms=5
      session.send "resumed"
    expect-equals "measured" session.receive
    return
  expect-equals "ready" session.receive
  if duty == 0.0 or duty == 1.0:
    // Count unfiltered edges: narrow glitches are missed by software polling.
    counter := pulse-counter.Unit pin
    try:
      sleep --ms=50
      expect-equals 0 counter.value
    finally:
      counter.close
    input := gpio.Pin pin --input
    try:
      expect-equals duty.to-int input.get
    finally:
      input.close
  else:
    input := rmt.In pin --resolution=8_000_000 --memory-blocks=2
    try:
      input.start-reading --max-ns=2_000_000
      session.send "capture"
      signals := input.wait-for-data
      expect-equals "stopped" session.receive
      expect signals.size >= 6
      // The first pulse can be partial, and the last can be an end marker.
      for i := 1; i < signals.size - 2; i++:
        expected := (signals.level i) == 1 ? duty : 1.0 - duty
        expected *= 1_000_000_000.0 / frequency
        expect ((signals.ns-duration i) - expected).abs <= (max 500 (expected * 0.03))
    finally:
      input.close
    session.send "resume"
    expect-equals "resumed" session.receive
    // Positive control for the counter used to reject endpoint glitches.
    counter := pulse-counter.Unit pin
    try:
      start := Time.monotonic-us
      sleep --ms=50
      elapsed := Time.monotonic-us - start
      expected := elapsed * frequency / 1_000_000.0
      expect (counter.value - expected).abs <= (max 2 (expected * 0.05))
    finally:
      counter.close
  session.send "measured"
