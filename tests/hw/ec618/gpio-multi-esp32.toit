// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
ESP32 observer for the EC618 concurrent GPIO-output regression.

The three inputs have pull-downs, so a released EC618 pad reads low while the other two wires remain independently observable.
*/

CONTROL-BAUD ::= 115200
STARTUP-TIMEOUT-MS ::= 120_000
CONTROL-TIMEOUT-MS ::= 15_000

main:
  control-owner := rig.esp32-uart 1 CONTROL-BAUD
  control := FramedChannel control-owner.port
  pins := [
    gpio.Pin wiring.ESP32-GPIO11-PIN --input --pull-down,
    gpio.Pin wiring.ESP32-GPIO24-PIN --input --pull-down,
    gpio.Pin wiring.ESP32-GPIO27-PIN --input --pull-down,
  ]
  connected := false

  try:
    while true:
      message := control.receive
          --timeout-ms=(connected ? CONTROL-TIMEOUT-MS : STARTUP-TIMEOUT-MS)
      parts := message.split " "
      if message == "HELLO":
        connected = true
        control.send "READY"
      else if parts.size == 2 and parts[0] == "CHECK":
        expected := parts[1]
        if expected.size != pins.size: throw "invalid pattern '$expected'"
        actual := "$(pins[0].get)$(pins[1].get)$(pins[2].get)"
        control.send "SEEN $actual"
        print "gpio-multi-esp32: expected=$expected observed=$actual"
      else if message == "Q":
        control.send "BYE"
        return
      else:
        throw "unexpected command '$message'"
  finally:
    pins.do: it.close
    control-owner.close
