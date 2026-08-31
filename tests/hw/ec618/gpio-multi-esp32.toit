// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import monitor

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
ESP32 observer for the EC618 concurrent GPIO-output regression.

The three inputs have pull-downs, so a released EC618 pad reads low while the
  other two wires remain independently observable.

The same helper also watches the GPIO11 wire for a pulse opposite to each
  requested initial output level. Its pull points toward that requested level,
  so a mux/configuration glitch cannot be hidden by a mismatched idle state.
*/

CONTROL-BAUD ::= 115200
STARTUP-TIMEOUT-MS ::= 120_000
CONTROL-TIMEOUT-MS ::= 15_000
GLITCH-WINDOW-MS ::= 200

capture-open-glitch control/FramedChannel pin/gpio.Pin level/int -> none:
  pin.configure
      --input
      --pull-up=(level == 1)
      --pull-down=(level == 0)
  result := monitor.Channel 1
  if pin.get != level:
    throw "GPIO11 did not settle to requested idle level $level"
  task::
    error := catch:
      with-timeout --ms=GLITCH-WINDOW-MS:
        pin.wait-for (1 - level)
    result.send error == null
  control.send "ARMED $level"
  control.expect "DONE" --timeout-ms=CONTROL-TIMEOUT-MS
  if result.receive:
    throw "opposite-level pulse observed while opening output at $level"
  control.send "CLEAN $level"

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
      else if parts.size == 2 and parts[0] == "GLITCH":
        level := int.parse parts[1]
        if level != 0 and level != 1: throw "invalid glitch level '$level'"
        capture-open-glitch control pins[0] level
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
