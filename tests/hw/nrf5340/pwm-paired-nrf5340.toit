// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import gpio.pwm show Pwm
import system

NRF-PINS ::= [32, 36, 8, 9]
ESP-PINS ::= [13, 32, 18, 23]
FREQUENCIES ::= [1000, 2000, 5000, 10_000]

main:
  expect-equals system.PLATFORM-ZEPHYR system.platform
  ack := gpio.Pin 33 --input --pull-down
  sequence := 0
  request := : |command/string|
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)

  generators := []
  4.repeat: |index|
    generator := Pwm --frequency=FREQUENCIES[index]
    generator.start NRF-PINS[index] --duty-factor=0.5
    generators.add generator
  4.repeat: |index|
    request.call "PWM_HZ $(ESP-PINS[index]) $(FREQUENCIES[index])"
  generators[1].close
  request.call "PWM_RELEASE $(ESP-PINS[1])"
  request.call "PWM_HZ $(ESP-PINS[0]) $(FREQUENCIES[0])"
  generators.do: it.close
  ESP-PINS.do: request.call "PWM_RELEASE $it"
  print "PWM independent controllers PASS"

  generator := Pwm --frequency=50 --max-frequency=10_000
  channels := NRF-PINS.map: generator.start it --duty-factor=0.5
  4.repeat: |index|
    channels[index].set-duty-factor (index + 1) / 4.0
    if index < 3:
      request.call "PWM_DUTY $(ESP-PINS[index]) $((index + 1) * 250)"
    else:
      request.call "PWM_LEVEL $(ESP-PINS[index]) 1"
  channels.do: it.set-duty-factor 0.5
  generator.frequency = 1000
  ESP-PINS.do: request.call "PWM_HZ $it 1000"
  channels[1].close
  request.call "PWM_RELEASE $(ESP-PINS[1])"
  request.call "PWM_HZ $(ESP-PINS[0]) 1000"
  replacement := generator.start NRF-PINS[1] --duty-factor=0.25
  generator.frequency = 50
  request.call "PWM_DUTY $(ESP-PINS[1]) 250"
  request.call "PWM_DUTY $(ESP-PINS[0]) 500"
  generator.frequency = 4
  request.call "PWM_DUTY $(ESP-PINS[0]) 500"
  generator.close
  ESP-PINS.do: request.call "PWM_RELEASE $it"
  print "PWM shared frequency, duty and channel remapping PASS"

  4.repeat: |cycle|
    generator = Pwm --frequency=10_000
    channel := generator.start 32 --duty-factor=0
    request.call "PWM_ARM 13"
    channel.set-duty-factor 0.5
    request.call "PWM_TRAIN 13"
    request.call "PWM_HZ 13 10000"
    channel.set-duty-factor 1
    request.call "PWM_ARM 13"
    channel.set-duty-factor 0
    request.call "PWM_STATIC 13 0"
    request.call "PWM_ARM 13"
    channel.set-duty-factor 1
    request.call "PWM_STATIC 13 1"
    channel.set-duty-factor 0.5
    request.call "PWM_HZ 13 10000"
    channel.close
    request.call "PWM_RELEASE 13"
    generator.close
    print "PWM static endpoints and recovery cycle=$cycle PASS"

  child := spawn::
    leaked := Pwm --frequency=1000
    leaked.start 32 --duty-factor=1
    sleep --ms=1000
  with-timeout --ms=2000:
    while true:
      probe/gpio.Pin? := null
      error := catch: probe = gpio.Pin 32 --input
      if probe: probe.close
      if error:
        expect-equals "ALREADY_IN_USE" error
        break
      sleep --ms=1
  request.call "PWM_LEVEL 13 1"
  with-timeout --ms=2000:
    while not (catch: child.priority): sleep --ms=1
  request.call "PWM_RELEASE 13"
  // Final teardown must release every controller and output, verified by the
  // runner's PWM_RELEASE cleanup commands after the VM has exited.
  NRF-PINS.do: |number|
    leaked := Pwm --frequency=1000
    leaked.start number --duty-factor=1
  ESP-PINS.do: request.call "PWM_LEVEL $it 1"
  print "NRF5340 PWM PAIRED PASS"
