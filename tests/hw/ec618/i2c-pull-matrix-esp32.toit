// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
ESP32 half of the EC618 I2C pull-up matrix.

The I2C0 wires remain inputs throughout. Commands over the framed UART2 control channel select whether the ESP32 supplies internal pull-ups:

```
P 0  // Inputs without pull-ups.
P 1  // Inputs with pull-ups.
L    // Report SCL and SDA levels.
Q    // Quit.
```

On a minimal rig without the UART2 control wires, launch `i2c-pull-standalone-matrix-esp32.toit`. Each EC618 phase ends with a two-level marker on SDA/SCL. The helper uses those markers to advance from no pulls, to ESP32 pull-ups, to passive observation of the EC618 pull-ups. It acknowledges the final observation on the same two wires after the EC618 closes its I2C bus.
*/

OBSERVER-TIMEOUT ::= Duration --s=120
STABLE-MS ::= 200

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

run-standalone-matrix -> none:
  inputs := I2cInputs --pull-up=false
  try:
    print "i2c-pull-matrix-esp32: no-pulls ready"
    wait-for-start-sequence inputs
  finally:
    inputs.close

  inputs = I2cInputs --pull-up
  try:
    wait-for-stable-levels inputs "1 1"
    print "i2c-pull-matrix-esp32: pull-ups ready"
    wait-for-start-sequence inputs
  finally:
    inputs.close

  observe-ec-pulls

observe-ec-pulls -> none:
  inputs := I2cInputs --pull-up=false
  observed := false
  try:
    wait-for-start-sequence inputs
    wait-for-stable-levels inputs "1 1"
    observed = true
  finally:
    if not observed:
      print "i2c-pull-matrix-esp32: FAIL did not observe EC618 pull-ups ($(inputs.levels))"
    inputs.close

  // Acknowledge the observed EC618 pull-ups after it closes its I2C bus.
  scl := gpio.Pin wiring.ESP32-I2C0-SCL-PIN --output --value=1
  sda := gpio.Pin wiring.ESP32-I2C0-SDA-PIN --output --value=0
  try:
    print "i2c-pull-matrix-esp32: PASS observed EC618 pull-ups"
    sleep --ms=10_000
  finally:
    sda.close
    scl.close

wait-for-start-sequence inputs/I2cInputs -> none:
  wait-for-stable-levels inputs "0 1"
  wait-for-stable-levels inputs "1 0"

wait-for-levels inputs/I2cInputs expected/string -> none:
  with-timeout OBSERVER-TIMEOUT:
    while inputs.levels != expected:
      sleep --ms=10

wait-for-stable-levels inputs/I2cInputs expected/string -> none:
  with-timeout OBSERVER-TIMEOUT:
    while true:
      wait-for-levels inputs expected
      sleep --ms=STABLE-MS
      if inputs.levels == expected: return
