// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import gpio.adc show Adc
import expect show *
import monitor show Semaphore

main:
  ack := gpio.Pin 33 --input --pull-down
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)

  [-1.0, float.NAN, float.INFINITY].do: | maximum |
    expect-equals "INVALID_ARGUMENT" (catch: Adc 4 --max-voltage=maximum)
  expect-equals "OUT_OF_RANGE" (catch: Adc 4 --max-voltage=3.7)
  [8, 32, 64, -1].do: | pin |
    expect-equals "INVALID_ARGUMENT" (catch: Adc pin)
  rollback := gpio.Pin 8 --input
  rollback.close
  owned := gpio.Pin 4 --input
  expect-equals "ALREADY_IN_USE" (catch: Adc 4)
  owned.close

  first := Adc 4
  second := Adc 5
  expect-equals "ALREADY_IN_USE" (catch: Adc 4)
  expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 5 --output)
  expect-equals "OUT_OF_BOUNDS" (catch: first.get --samples=0)
  expect-equals "INVALID_ARGUMENT" (catch: first.get --no-raw)
  staircase := []
  7.repeat: | step |
    mv := step * 500
    request.call "ADC_DAC $mv $(3000 - mv)"
    sleep --ms=5
    a := first.get
    b := second.get
    print "ADC DAC=$mv/$(3000 - mv) mV measured=$(%.4f a)/$(%.4f b) V"
    near (mv / 1000.0) a 0.2
    near ((3000 - mv) / 1000.0) b 0.2
    near a ((first.get --raw) * 3.6 / 4096) 0.02
    near b ((second.get --raw) * 3.6 / 4096) 0.02
    staircase.add [a, b]
  // Relative linearity between endpoints, independently on each wire.
  2.repeat: | channel |
    low/float := staircase[0][channel]
    high/float := staircase[6][channel]
    expect ((high - low).abs > 2.5)
    5.repeat: | index |
      near (low + (high - low) * (index + 1) / 6) staircase[index + 1][channel] 0.08
  print "ADC voltage staircase, raw values and linearity PASS"
  first.close
  second.close

  // Compare each gain to the same voltage measured on the widest range.
  // The DAC's offset makes it unsuitable for checking absolute millivolts.
  [0.15, 0.3, 0.6, 1.2, 1.8, 2.4, 3.0, 3.6].do: | maximum/float |
    mv := maximum < 0.3 ? 0 : (maximum * 400).to-int
    request.call "ADC_DAC $mv $mv"
    sleep --ms=5
    [4, 5].do: | pin/int |
      wide := Adc pin
      baseline := wide.get
      wide.close
      narrow := Adc pin --max-voltage=maximum
      near baseline narrow.get 0.025
      raw := narrow.get --raw
      expect (0 <= raw <= 4095)
      near baseline (raw * maximum / 4096) 0.025
      narrow.close
  // Saturation at a narrow range must not affect the other channel's gain.
  request.call "ADC_DAC 1500 1500"
  saturated := Adc 4 --max-voltage=0.6
  expect ((saturated.get --raw) >= 4090) --message="ADC narrow-range saturation"
  near 0.6 saturated.get 0.005
  saturated.close
  // A maximum between hardware ranges rounds up, including the raw scaling.
  request.call "ADC_DAC 500 1500"
  first = Adc 4 --max-voltage=1.01
  second = Adc 5
  reference := first.get
  near reference ((first.get --raw) * 1.2 / 4096) 0.02
  [1, 2, 17, 63, 64, 65, 127, 129].do: | count |
    near reference (first.get --samples=count) 0.02
  print "ADC all gains, range rounding and sample counts PASS"

  // Long averages cross many bounded native calls. Timers must still run,
  // and cancellation must not leave a stale conversion or a locked ADC.
  ticks := 0
  ticker := task::
    while true:
      ticks++
      sleep --ms=1
  sleep --ms=2
  before := ticks
  near reference (first.get --samples=4096) 0.02
  expect (ticks > before + 2) --message="ADC long average starved ticker: $before -> $ticks"
  expect-equals "DEADLINE_EXCEEDED" (catch:
    with-timeout --ms=10: first.get --samples=16384)
  near reference first.get 0.02
  near 1.5 second.get 0.2
  print "ADC long average and deadline recovery PASS"
  cancel-done := Semaphore
  completed := false
  reader := task::
    try:
      first.get --samples=16384
      completed = true
    finally:
      critical-do: cancel-done.up
  sleep --ms=10
  reader.cancel
  with-timeout --ms=2000: cancel-done.down
  expect (not completed) --message="ADC reader completed before task cancellation"
  near reference first.get 0.02
  print "ADC task cancellation recovery PASS"
  ticker.cancel

  done := Semaphore
  task::
    20.repeat:
      near reference first.get 0.02
      yield
    done.up
  20.repeat:
    near 1.5 second.get 0.2
    yield
  with-timeout --ms=2000: done.down
  first.close
  second.close
  first.close
  expect-not-null (catch: first.get)
  print "ADC concurrent channels and cancellation recovery PASS"

  64.repeat: | cycle |
    pin := cycle % 2 == 0 ? 4 : 5
    adc := Adc pin --max-voltage=0.0
    near (pin == 4 ? reference : 1.5) ((adc.get --raw) * 3.6 / 4096)
        (pin == 4 ? 0.02 : 0.2)
    near (pin == 4 ? reference : 1.5) adc.get (pin == 4 ? 0.02 : 0.2)
    adc.close
    gpio-pin := gpio.Pin pin --input
    gpio-pin.close
  print "ADC 64 close and reacquire cycles PASS"

  // A child exits with both ADCs open. Observe ownership before it exits,
  // then reclaim both pins in the parent, without rebooting the VM.
  child := spawn::
    adc-a := Adc 4
    adc-b := Adc 5
    near 0.5 adc-a.get 0.2
    near 1.5 adc-b.get 0.2
    indicator := gpio.Pin 32 --output --value=1
    sleep --ms=500
  with-timeout --ms=2000:
    while true:
      probe/Adc? := null
      error := catch: probe = Adc 4
      if probe: probe.close
      if error:
        expect-equals "ALREADY_IN_USE" error
        break
      sleep --ms=1
  request.call "WAIT 13 1"
  with-timeout --ms=2000:
    while not (catch: child.priority): sleep --ms=1
  first = Adc 4
  second = Adc 5
  near reference first.get 0.02
  near 1.5 second.get 0.2
  first.close
  second.close
  request.call "CONFIG 13 DOWN 0"
  request.call "CHECK 13 0"
  print "ADC process cleanup and parent reacquisition PASS"

  // Exercise borrowed-pin compatibility without transferring GPIO ownership.
  borrowed := gpio.Pin 4 --input
  adc := Adc borrowed
  near reference adc.get 0.02
  adc.close
  expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 4 --input)
  borrowed.close
  // Leave ADC resources open for final VM teardown too.
  first = Adc 4
  second = Adc 5
  first.get
  second.get
  indicator := gpio.Pin 32 --output --value=1
  request.call "CHECK 13 1"
  print "NRF5340 ADC PASS"

near expected/float actual/float tolerance/float:
  expect ((actual - expected).abs <= tolerance)
      --message="ADC expected $expected +/- $tolerance, got $actual"
