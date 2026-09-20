// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import i2c

import .test
import .variants

I2C-SDA ::= Variant.CURRENT.board-connection-pin3
I2C-SCL ::= Variant.CURRENT.board-connection-pin5
CONTROLLER-READY ::= Variant.CURRENT.board-connection-pin6
TARGET-READY ::= Variant.CURRENT.board-connection-pin4

ADDRESS ::= 0x42
TEST-LENGTH ::= 20
REPETITIONS ::= 3

main:
  run-test: test

test:
  controller-ready := gpio.Pin CONTROLLER-READY --output --value=0
  target-ready := gpio.Pin TARGET-READY --input --pull-down
  bus := i2c.Bus --sda=I2C-SDA --scl=I2C-SCL --frequency=100_000 --pull-up
  device := bus.device ADDRESS
  try:
    REPETITIONS.repeat: | repetition/int |
      controller-ready.set 1
      wait-for-level target-ready 1
      error := catch: device.write (pattern TEST-LENGTH)
      controller-ready.set 0
      wait-for-level target-ready 0
      print "controller repetition=$repetition error=$error"
  finally:
    controller-ready.set 0
    device.close
    bus.close
    target-ready.close
    controller-ready.close

pattern size/int -> ByteArray:
  return ByteArray size: (it * 31 + 23) & 0xff

wait-for-level pin/gpio.Pin level/int -> none:
  with-timeout --ms=5_000:
    while pin.get != level: sleep --ms=1
