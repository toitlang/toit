// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
ESP32 half of the EC618 I2C pull-up matrix.

The I2C0 wires remain inputs throughout. Commands over the framed UART2
  control channel select whether the ESP32 supplies internal pull-ups:

```
P 0  // Inputs without pull-ups.
P 1  // Inputs with pull-ups.
L    // Report SCL and SDA levels.
Q    // Quit.
```
*/

class I2cInputs:
  scl/gpio.Pin
  sda/gpio.Pin

  constructor --pull-up/bool:
    if pull-up:
      scl = gpio.Pin wiring.ESP32-I2C0-SCL-PIN --input --pull-up
      sda = gpio.Pin wiring.ESP32-I2C0-SDA-PIN --input --pull-up
    else:
      scl = gpio.Pin wiring.ESP32-I2C0-SCL-PIN --input
      sda = gpio.Pin wiring.ESP32-I2C0-SDA-PIN --input

  levels -> string:
    return "$(scl.get) $(sda.get)"

  close -> none:
    sda.close
    scl.close

main:
  control-owner := rig.esp32-uart 2 115200
  control := FramedChannel control-owner.port
  inputs := I2cInputs --pull-up=false
  connected := false
  print "i2c-pull-matrix-esp32: ready (SCL IO$(wiring.ESP32-I2C0-SCL-PIN), SDA IO$(wiring.ESP32-I2C0-SDA-PIN))"

  try:
    while true:
      message := control.receive --timeout-ms=(connected ? 15_000 : 120_000)
      if message == "HELLO":
        connected = true
        control.send "READY"
        continue
      if message == "L":
        control.send "L $(inputs.levels)"
        continue
      if message == "Q":
        control.send "BYE"
        return

      parts := message.split " "
      if parts.size == 2 and parts[0] == "P" and
          (parts[1] == "0" or parts[1] == "1"):
        pull-up := parts[1] == "1"
        inputs.close
        inputs = I2cInputs --pull-up=pull-up
        control.send "P $(pull-up ? 1 : 0) $(inputs.levels)"
      else:
        throw "unexpected command '$message'"
  finally:
    inputs.close
    control-owner.close
