// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import gpio

/**
EC618 half of the alternate-pad GPIO output test.

GPIO14 and GPIO15 have primary ALT0 pads 29/30 and alternate ALT4 pads 13/14.
  The alternate pads are wired to ESP32 IO17/18 on the rig. Drive distinct square
  waves on both so the helper can prove that `Ec618.gpio --alt` resolves and muxes
  both physical pads correctly.

Start gpio-alt-esp32.toit on the ESP32 first, then run this file through the
  mini-jag tester.
*/

DURATION ::= Duration --s=20
HALF-14 ::= Duration --ms=25  // 20 Hz.
HALF-15 ::= Duration --ms=40  // 12.5 Hz.

drive pin/gpio.Pin half/Duration deadline/int:
  value := 0
  while Time.monotonic-us < deadline:
    value = 1 - value
    pin.set value
    sleep half
  pin.set 0

main:
  gpio14 := Ec618.gpio 14 --alt
  gpio15 := Ec618.gpio 15 --alt
  gpio14.configure --output --value=0
  gpio15.configure --output --value=0

  print "gpio-alt-ec618: GPIO14/PAD13 and GPIO15/PAD14 for $(DURATION.in-s)s"
  deadline := Time.monotonic-us + DURATION.in-us
  task:: drive gpio14 HALF-14 deadline
  drive gpio15 HALF-15 deadline
  // Let the faster background task finish its last half-period before closing.
  sleep --ms=50

  gpio14.close
  gpio15.close
  print "gpio-alt-ec618: PASS alternate pads driven"
