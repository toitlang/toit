// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import gpio.dac as dac
import .control as control
import .session
import .wiring

main:
  session := Session
  reserved := IS-TESTEE ? null : (gpio.Pin 25 --input)
  try:
    [1, 17, 255, 1024, 4096].do: | size |
      control.run-case session "UART $size":
        data := ByteArray size: (it * 37 + size) & 255
        expect-equals data (control.call session ["echo", data])
    GPIO-LINKS.do: | pin peer |
      control.run-case session "GPIO $pin output/open-drain/input/interrupt":
        local := gpio.Pin peer --input
        try:
          control.call session ["pin", pin, "output"]
          [1, 0, 1, 0].do: | value |
            control.call session ["set", pin, value]
            expect-equals value local.get
          control.call session ["open-drain", pin]
          local.set-pull --up
          [1, 0, 1].do: | value |
            control.call session ["set", pin, value]
            expect-equals value local.get
        finally:
          local.close
        control.call session ["pin", pin, "input"]
        local = gpio.Pin peer --output --value=0
        try:
          [1, 0].do: | value |
            session.send ["wait", pin, value]
            sleep --ms=50
            local.set value
            expect-equals value session.receive
            expect-equals value (control.call session ["read", pin])
        finally:
          local.close
    control.run-case session "GPIO pulls against 1 MOhm bias":
      observer := gpio.Pin HELPER-PULL --input
      bias := gpio.Pin HELPER-BIAS --output --value=0
      try:
        control.call session ["pin", H2-PULL, "input"]
        [0, 1].do: | value |
          bias.set value
          [0, 1, 2].do: | pull |
            control.call session ["pull", H2-PULL, pull]
            sleep --ms=10
            expected := pull == 0 ? value : (pull == 1 ? 1 : 0)
            expect-equals expected observer.get
            expect-equals expected (control.call session ["read", H2-PULL])
      finally:
        bias.close
        observer.close
    control.run-case session "ADC":
      analog := dac.Dac HELPER-DAC --initial-voltage=0.3
      try:
        [0.3, 0.8, 1.5].do: | voltage |
          analog.set voltage
          sleep --ms=20
          measured := control.call session ["adc"]
          print "ADC stimulus=$voltage observed=$measured"
          expect (measured - voltage).abs < 0.2
      finally:
        analog.close
    session.finish
  finally:
    if reserved: reserved.close
    session.close
