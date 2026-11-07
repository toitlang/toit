// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import gpio.pwm
import uart

// Verified rig: GP16 -> input-only ESP32 GPIO34, GP17 <- ESP32 GPIO4.
main:
  pin := gpio.Pin 16 --input --output --value=0
  try:
    expect-equals 0 pin.get
    pin.set 1
    expect-equals 1 pin.get
    pin.configure --input --output --open-drain --pull-up --value=1
    sleep --ms=1
    expect-equals 1 pin.get
    pin.set 0
    expect-equals 0 pin.get
    generator := pwm.Pwm --frequency=100
    try:
      expect-throw "ALREADY_IN_USE": generator.start 16
    finally:
      generator.close
  finally:
    pin.close
  print "pwm-gpio-rp2040: PASS GPIO and pin reservation"
  port := uart.Port --rx=17 --baud-rate=115_200
  generator := pwm.Pwm --frequency=100 --max-frequency=8_000
  try:
    expect-throw "OUT_OF_RANGE": generator.start 30
    expect-throw "PERMISSION_DENIED": generator.start 0
    channel := generator.start 16
    try:
      expect-throw "ALREADY_IN_USE": gpio.Pin 16 --input
      expect-throw "ALREADY_IN_USE": generator.start 16
      print "pwm-gpio-rp2040: READY"
      with-timeout --ms=180_000:
        5.repeat:
          fields := (port.in.read-string-up-to '\n').split " "
          expect-equals 2 fields.size
          generator.frequency = int.parse fields[0]
          duty := (int.parse fields[1]) / 100.0
          channel.set-duty-factor duty
          expect-equals duty channel.duty-factor
        expect-equals "DONE" (port.in.read-string-up-to '\n')
    finally:
      channel.close
  finally:
    generator.close
    port.close
  20.repeat:
    generator = pwm.Pwm --frequency=100
    channel := generator.start 16 --duty-factor=0
    channel.close
    generator.close
    pin = gpio.Pin 16 --input
    pin.close
  print "pwm-gpio-rp2040: PASS"
