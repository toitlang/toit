// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests gpio pin configurations.

Setup: connect pin1-id to pin2-id, optionally with a 330 Ohm resistor to avoid short circuits.
*/

import gpio
import expect show *

RESTRICTED ::= 7
PIN1 ::= 18
PIN2 ::= 19

interface PinFactory:
  pin -> gpio.Pin
      pin-identifier
      --use-constructor/bool=false
      --input/bool=false
      --output/bool=false
      --pull-down/bool=false
      --pull-up/bool=false
      --open-drain/bool=false

test-configurations pin-factory/PinFactory pin1-id pin2-id:
  2.repeat: | i |
    use-constructor := (i == 0)
    print "Using constructors: $use-constructor"

    pin1 := pin-factory.pin pin1-id --use-constructor=use-constructor --output
    pin2 := pin-factory.pin pin2-id --use-constructor=use-constructor --input

    if use-constructor: expect-equals 0 pin2.get
    pin1.set 0
    expect-equals 0 pin2.get
    pin1.set 1
    expect-equals 1 pin2.get

    pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --pull-down
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --pull-up
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get

    // Try the pull-down/pull-up again to ensure that we weren't just lucky.
    pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --pull-down
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --pull-up
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get

    expect-throw "INVALID_ARGUMENT":
      pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --pull-up --pull-down
    expect-throw "INVALID_ARGUMENT":
      pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --output --pull-up --pull-down

    pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --pull-up
    pin2 = pin-factory.pin pin2-id --use-constructor=use-constructor --output
    // Override the pull up of pin1
    pin2.set 0
    expect-equals 0 pin1.get
    pin2.set 1
    expect-equals 1 pin1.get

    pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --pull-up
    pin2 = pin-factory.pin pin2-id --use-constructor=use-constructor --output
    pin2.set 0
    expect-equals 0 pin1.get
    // Override the pull down of pin1
    pin2.set 1
    expect-equals 1 pin1.get

    pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --pull-up
    pin2 = pin-factory.pin pin2-id --use-constructor=use-constructor --output --open-drain
    pin2.set 1
    expect-equals 1 pin1.get
    // Since pin2 is output only, we can't ask for its value.

    pin2.set 0
    expect-equals 0 pin1.get

    pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --pull-up
    pin2 = pin-factory.pin pin2-id --use-constructor=use-constructor --input --output --open-drain
    pin2.set 1
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get

    pin2.set 0
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    pin1 = pin-factory.pin pin1-id --use-constructor=use-constructor --input --output --open-drain --pull-up
    pin1.set 0
    pin2.set 0
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    pin1.set 1
    pin2.set 0
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    pin1.set 0
    pin2.set 1
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    pin1.set 1
    pin2.set 1
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get
