// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
ESP32 half of the EC618 I2C clock-stretch test: power switch + SCL squatter.

Extends the bmp280-esp32 power helper with a stretch command: the ESP32 plays the stretching slave by holding the SCL net low, OPEN-DRAIN ONLY (drive low / release to high-Z — never push high, so there is no contention with the master; this is electrically exactly what a real clock-stretching slave does).

Commands over the framed UART2 control channel: "P 1" / "P 0"      -> sensor power on/off (replies "P <v>") "H <delay> <hold>" -> reply "H ok" immediately, then after <delay> ms hold SCL low for <hold> ms and release. "Q"                -> power off + quit.
*/

main:
  control-owner := rig.esp32-uart 2 115200
  control := FramedChannel control-owner.port
  power := gpio.Pin wiring.ESP32-SENSOR-POWER-PIN --output --value=0
  // Open-drain, idle released: value 1 = high-Z (the bus pull-up rules),
  // value 0 = actively held low. Never drives high.
  scl := gpio.Pin wiring.ESP32-I2C1-SCL-PIN --output --open-drain --value=1
  connected := false
  print "i2c-stretch-esp32: ready (power IO$(wiring.ESP32-SENSOR-POWER-PIN), SCL squat IO$(wiring.ESP32-I2C1-SCL-PIN) open-drain)"

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
      if parts.size == 2 and parts[0] == "P":
        if parts[1] != "0" and parts[1] != "1":
          throw "invalid power command '$message'"
        value := int.parse parts[1]
        power.set value
        if value == 1: sleep --ms=20  // Sensor start-up.
        control.send "P $value"
        print "i2c-stretch-esp32: power $value"
      else if parts.size == 3 and parts[0] == "H":
        delay := int.parse parts[1]
        hold := int.parse parts[2]
        if delay < 0 or hold <= 0: throw "invalid hold command '$message'"
        control.send "H ok"
        task::
          sleep --ms=delay
          scl.set 0
          print "i2c-stretch-esp32: SCL held low ($hold ms)"
          sleep --ms=hold
          scl.set 1
          print "i2c-stretch-esp32: SCL released"
      else:
        throw "unexpected command '$message'"
  finally:
    power.set 0
    power.close
    scl.set 1
    scl.close
    control-owner.close
