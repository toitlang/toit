// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
ESP32 half of the alternate-pad GPIO output test.

EC618 PAD13 / GPIO14 ALT4 is wired to IO17, and PAD14 / GPIO15 ALT4 to IO18.
  A framed UART1 command names the pattern that this side must read on the two
  wires. The acknowledgement includes the observed pattern.
*/

main:
  control-owner := rig.esp32-uart 1 115200
  control := FramedChannel control-owner.port
  gpio14 := gpio.Pin wiring.ESP32-GPIO14-ALT-PIN --input --pull-down
  gpio15 := gpio.Pin wiring.ESP32-GPIO15-ALT-PIN --input --pull-down
  connected := false

  try:
    while true:
      message := control.receive --timeout-ms=(connected ? 15_000 : 120_000)
      if message == "HELLO":
        connected = true
        control.send "READY"
        continue
      if message == "Q":
        control.send "BYE"
        return

      parts := message.split " "
      if not connected or parts.size != 2 or parts[0] != "CHECK":
        throw "unexpected command '$message'"
      expected := parts[1]
      if expected.size != 2 or
          (expected[0] != '0' and expected[0] != '1') or
          (expected[1] != '0' and expected[1] != '1'):
        throw "invalid pattern '$expected'"
      actual := "$(gpio14.get)$(gpio15.get)"
      print "gpio-alt-esp32: expected=$expected actual=$actual"
      control.send "READ $actual"
  finally:
    gpio15.close
    gpio14.close
    control-owner.close
