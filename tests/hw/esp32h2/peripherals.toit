// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import gpio.adc as adc
import gpio.pwm as pwm
import pulse-counter
import .control
import .wiring

main:
  control := Control
  try:
    [1, 17, 255, 1024, 4096].do: | size |
      control.echo (ByteArray size: (it * 37 + size) & 255)
    print "UART bidirectional payloads passed"
    GPIO-LINKS.do: | pin peer |
      control.command INPUT peer 0
      local := gpio.Pin pin --output
      [1, 0, 1, 0].do: | value |
        local.set value
        expect-equals value (control.read peer)
      local.set-open-drain true
      control.command INPUT peer 1
      [1, 0, 1].do: | value |
        local.set value
        expect-equals value (control.read peer)
      local.close
      control.command OUTPUT peer 0
      local = gpio.Pin pin --input
      [1, 0].do: | value |
        control.command DELAYED-OUTPUT peer value
        local.wait-for value
        expect-equals value local.get
      local.close
      control.command INPUT peer 0
    print "GPIO output, open drain, input, and interrupt checks passed"

    control.command INPUT HELPER-PULL 0
    local := gpio.Pin H2-PULL --input
    [0, 1].do: | bias |
      control.command OUTPUT HELPER-BIAS bias
      local.set-pull --off
      sleep --ms=10
      expect-equals bias local.get
      local.set-pull --up
      sleep --ms=10
      expect-equals 1 local.get
      local.set-pull --down
      sleep --ms=10
      expect-equals 0 local.get
    local.close
    control.command INPUT HELPER-BIAS 0
    print "GPIO pulls passed against 1 MOhm bias"

    analog := adc.Adc H2-ADC
    [0.3, 0.8, 1.5].do: | voltage |
      control.command DAC HELPER-DAC (voltage * 100).to-int
      sleep --ms=20
      measured := analog.get --samples=128
      print "ADC requested=$voltage measured=$measured"
      expect (measured - voltage).abs < 0.2
    analog.close
    control.command INPUT HELPER-DAC 0

    control.command OUTPUT 14 0
    unit := pulse-counter.Unit 1
    control.command PULSES 14 100
    expect-equals ACK control.port.in.read-byte
    expect-equals 100 unit.value
    unit.close
    control.command INPUT 14 0
    print "Pulse counter passed"

    generator := pwm.Pwm --frequency=1000
    channel := generator.start 1 --duty-factor=0.5
    count := control.count 14
    print "PWM pulses in 200ms: $count"
    expect 180 <= count <= 220
    channel.close
    generator.close
  finally:
    control.close
  print "All tests done"
