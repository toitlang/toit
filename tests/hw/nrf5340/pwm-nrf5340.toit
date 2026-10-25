// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import gpio.pwm show Pwm
import system

PINS ::= [32, 36, 8, 9]

main:
  expect-equals system.PLATFORM-ZEPHYR system.platform
  [0, 1, 3, -1, 5_333_334].do: |frequency|
    expect-equals "INVALID_ARGUMENT" (catch: Pwm --frequency=frequency)
  expect-equals "INVALID_ARGUMENT" (catch: Pwm --frequency=100 --max-frequency=50)
  // Every controller must be independently usable; a fifth must fail cleanly.
  generators := []
  4.repeat: generators.add (Pwm --frequency=50 --max-frequency=1_000_000)
  expect-equals "ALREADY_IN_USE" (catch: Pwm --frequency=50)
  generators.size.repeat: |index|
    generator/Pwm := generators[index]
    channel := generator.start PINS[index] --duty-factor=(index / 4.0)
    expect-equals "ALREADY_IN_USE" (catch: gpio.Pin PINS[index] --input)
    expect-equals (index / 4.0) channel.duty-factor
    generator.frequency = 1000
    expect-equals 1000 generator.frequency
  generators.do: it.close
  generators.do: it.close
  PINS.do: (gpio.Pin it --input).close

  16.repeat: |cycle|
    generator := Pwm --frequency=50 --max-frequency=1_000_000
    [0, 1, 18, 20, 22, 64, -1].do: |pin|
      expect-equals "INVALID_ARGUMENT" (catch: generator.start pin)
    expect-equals "INVALID_ARGUMENT" (catch: generator.start 32 --duty-factor=float.NAN)
    channels := PINS.map: generator.start it --duty-factor=0.25
    expect-equals "QUOTA_EXCEEDED" (catch: generator.start 12)
    (gpio.Pin 12 --input).close
    channels.do: |channel|
      channel.set-duty-factor -1
      expect-equals 0.0 channel.duty-factor
      channel.set-duty-factor float.INFINITY
      expect-equals 1.0 channel.duty-factor
      expect-equals "INVALID_ARGUMENT" (catch: channel.set-duty-factor float.NAN)
      expect-equals 1.0 channel.duty-factor
      channel.set-duty-factor 0.75
    [4, 50, 1000, 1_000_000].do: |frequency|
      generator.frequency = frequency
      expect-equals frequency generator.frequency
      channels.do: expect ((it.duty-factor - 0.75).abs < 0.001)
    expect-equals "INVALID_ARGUMENT" (catch: generator.frequency = 1_000_001)
    expect-equals 1_000_000 generator.frequency
    channels[1].close
    (gpio.Pin PINS[1] --input).close
    replacement := generator.start PINS[1] --duty-factor=0.5
    expect-equals 0.5 replacement.duty-factor
    channels[0].close
    channels[0].close
    generator.close
    PINS.do: (gpio.Pin it --input).close
    print "PWM lifecycle cycle=$cycle PASS"

  // Read the PWM-driven pad through its digital input buffer. This requires
  // no extra wire, but does not replace measurement by the external fixture.
  pin := gpio.Pin 32 --input --output
  generator := Pwm --frequency=50 --max-frequency=100
  channel := generator.start pin
  expect-equals "ALREADY_IN_USE" (catch: generator.start pin)
  pin.configure --input --output
  expect-equals 0 pin.get
  channel.set-duty-factor 1
  sleep --ms=25
  expect-equals 1 pin.get
  [0.25, 0.5, 0.75].do: |factor/float|
    channel.set-duty-factor factor
    sleep --ms=25
    measure pin 50 factor
  generator.frequency = 100
  pin.configure --input --output
  measure pin 100 0.75
  channel.close
  pin.configure --input
  // Closing a borrowed channel must leave the original Pin reserved.
  expect-equals "ALREADY_IN_USE" (catch: gpio.Pin 32 --input)
  pin.close
  generator.close

  child := spawn::
    leaked := Pwm --frequency=50
    leaked.start 32 --duty-factor=0.5
    sleep --ms=500
  with-timeout --ms=2000:
    while true:
      probe/gpio.Pin? := null
      error := catch: probe = gpio.Pin 32 --input
      if probe: probe.close
      if error:
        expect-equals "ALREADY_IN_USE" error
        break
      sleep --ms=1
  with-timeout --ms=2000:
    while not (catch: child.priority): sleep --ms=1
  (gpio.Pin 32 --input).close
  // Leave every controller active for VM teardown and external pin checks.
  PINS.do: |number|
    leaked := Pwm --frequency=50
    leaked.start number --duty-factor=0.5
  print "NRF5340 PWM PASS: controllers, channels, ownership, waveform and process cleanup"

measure pin/gpio.Pin frequency/int factor/float:
  with-timeout --ms=2000:
    pin.wait-for 0
    pin.wait-for 1
    start := Time.monotonic-us
    previous := start
    high := 0
    16.repeat:
      pin.wait-for 0
      low := Time.monotonic-us
      high += low - previous
      pin.wait-for 1
      previous = Time.monotonic-us
    elapsed := previous - start
    measured := 16_000_000.0 / elapsed
    duty := high.to-float / elapsed
    expect ((measured / frequency - 1).abs < 0.1)
    expect ((duty - factor).abs < 0.1)
    print "PWM pad frequency=$measured duty=$duty PASS"
