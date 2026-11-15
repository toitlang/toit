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

  // Pin objects cannot bypass peripheral ownership on this platform.
  pin := gpio.Pin 32 --input
  generator := Pwm --frequency=50 --max-frequency=100
  expect-throw "INVALID_ARGUMENT": generator.start pin
  expect-throw "INVALID_ARGUMENT": generator.start -34
  expect-throw "ALREADY_IN_USE": generator.start 32
  pin.close
  channel := generator.start 32
  expect-throw "ALREADY_IN_USE": gpio.Pin 32 --input
  channel.close
  (gpio.Pin 32 --input).close
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
  print "NRF5340 PWM PASS: controllers, channels, ownership and process cleanup"
