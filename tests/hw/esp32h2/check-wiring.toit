// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import .control as control
import .session
import .wiring

main:
  session := Session
  reserved := IS-TESTEE ? null : (gpio.Pin 25 --input)
  try:
    control.run-case session "Wiring: control UART":
      // These two wires remain assigned to UART throughout the pre-check.
      data := ByteArray 256: it
      expect-equals data (control.call session ["echo", data])
    control.run-case session "Wiring: GPIO links in both directions":
      pins := {:}
      bias := gpio.Pin HELPER-BIAS --input
      try:
        GPIO-LINKS.do: | pin peer |
          pins[peer] = gpio.Pin peer --input --pull-up
          control.call session ["pin", pin, "input"]
          control.call session ["pull", pin, 1]
        GPIO-LINKS.do: | pin peer |
          control.call session ["pin", pin, "output"]
          control.call session ["open-drain", pin]
          [1, 0, 1].do: | level |
            control.call session ["set", pin, level]
            sleep --ms=10
            GPIO-LINKS.values.do: | observer |
              expect-equals (observer == peer ? level : 1) pins[observer].get
            print "H2 $pin -> ESP32 $peer level=$level: all lines checked"
          control.call session ["pin", pin, "input"]
          control.call session ["pull", pin, 1]
        GPIO-LINKS.do: | pin peer |
          pins[peer].close
          pins.remove peer
          pins[peer] = gpio.Pin peer --output --open-drain --value=1
          [1, 0, 1].do: | level |
            pins[peer].set level
            sleep --ms=10
            expected := {:}
            GPIO-LINKS.keys.do: expected[it] = it == pin ? level : 1
            expect-structural-equals expected (control.call session ["levels"])
            print "ESP32 $peer -> H2 $pin level=$level: all lines checked"
          pins[peer].close
          pins.remove peer
          pins[peer] = gpio.Pin peer --input --pull-up
      finally:
        pins.values.do: it.close
        bias.close
    control.run-case session "Wiring: resistor and pulls":
      observer := gpio.Pin HELPER-PULL --input
      bias := gpio.Pin HELPER-BIAS --output --value=0
      try:
        control.call session ["pin", H2-PULL, "input"]
        [[0, 0, 0], [0, 1, 1], [1, 0, 1], [2, 1, 0]].do: | config |
          pull := config[0]
          bias.set config[1]
          control.call session ["pull", H2-PULL, pull]
          sleep --ms=10
          expect-equals config[2] observer.get
          expect-equals config[2] (control.call session ["read", H2-PULL])
          print "Resistor pull=$pull bias=$config[1]: both readings checked"
      finally:
        bias.close
        observer.close
    session.finish
  finally:
    if reserved: reserved.close
    session.close
