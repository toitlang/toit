// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
ESP32 driver for the EC618 AON-pad GPIO-input regression.

The two test pins remain high impedance until the EC618 reports that its inputs
  are ready. Each requested output pattern is acknowledged after it is driven.
*/

main:
  control-owner := rig.esp32-uart 1 115200
  control := FramedChannel control-owner.port
  first := gpio.Pin wiring.ESP32-GPIO24-PIN
  second := gpio.Pin wiring.ESP32-GPIO27-PIN
  configured := false

  try:
    while true:
      message := control.receive --timeout-ms=(configured ? 15_000 : 120_000)
      if message == "HELLO":
        first.configure --output --value=0
        second.configure --output --value=0
        configured = true
        control.send "READY"
      else if message == "Q":
        if configured:
          first.set 0
          second.set 0
        control.send "BYE"
        return
      else:
        parts := message.split " "
        if not configured or parts.size != 2 or parts[0] != "SET":
          throw "unexpected command '$message'"
        pattern := parts[1]
        if pattern.size != 2 or
            (pattern[0] != '0' and pattern[0] != '1') or
            (pattern[1] != '0' and pattern[1] != '1'):
          throw "invalid pattern '$pattern'"
        first.set pattern[0] - '0'
        second.set pattern[1] - '0'
        control.send "SET $pattern"
  finally:
    second.close
    first.close
    control-owner.close
