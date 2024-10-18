// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests gpio pin configurations.

Setup: connect pin1-id to pin2-id, optionally with a 330 Ohm resistor to avoid short circuits.
*/

import gpio
import expect show *
import monitor

RESTRICTED ::= 7
PIN1 ::= 18
PIN2 ::= 19

interface PinFactory:
  use-constructor= value/bool
  pin -> gpio.Pin
      pin-identifier
      --input/bool=false
      --output/bool=false
      --pull-down/bool=false
      --pull-up/bool=false
      --open-drain/bool=false
      --value/int?=null

test-configurations pin-factory/PinFactory pin1-id pin2-id:
  2.repeat: | i |
    use-constructor := (i == 0)
    print "Using constructors: $use-constructor"
    pin-factory.use-constructor = use-constructor

    pin1 := pin-factory.pin pin1-id --output
    pin2 := pin-factory.pin pin2-id --input

    if use-constructor: expect-equals 0 pin2.get
    pin1.set 0
    expect-equals 0 pin2.get
    pin1.set 1
    expect-equals 1 pin2.get

    pin1 = pin-factory.pin pin1-id --input --pull-down
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    pin1 = pin-factory.pin pin1-id --input --pull-up
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get

    // Try the pull-down/pull-up again to ensure that we weren't just lucky.
    pin1 = pin-factory.pin pin1-id --input --pull-down
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    pin1 = pin-factory.pin pin1-id --input --pull-up
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get

    expect-throw "INVALID_ARGUMENT":
      pin1 = pin-factory.pin pin1-id --input --pull-up --pull-down
    expect-throw "INVALID_ARGUMENT":
      pin1 = pin-factory.pin pin1-id --output --pull-up --pull-down

    pin1 = pin-factory.pin pin1-id --input --pull-up
    pin2 = pin-factory.pin pin2-id --output
    // Override the pull up of pin1
    pin2.set 0
    expect-equals 0 pin1.get
    pin2.set 1
    expect-equals 1 pin1.get

    pin1 = pin-factory.pin pin1-id --input --pull-up
    pin2 = pin-factory.pin pin2-id --output
    pin2.set 0
    expect-equals 0 pin1.get
    // Override the pull down of pin1
    pin2.set 1
    expect-equals 1 pin1.get

    pin1 = pin-factory.pin pin1-id --input --pull-up
    pin2 = pin-factory.pin pin2-id --output --open-drain
    pin2.set 1
    sleep --ms=10
    expect-equals 1 pin1.get
    // Since pin2 is output only, we can't ask for its value.

    pin2.set 0
    expect-equals 0 pin1.get

    pin1 = pin-factory.pin pin1-id --input --pull-up
    pin2 = pin-factory.pin pin2-id --input --output --open-drain
    pin2.set 1
    sleep --ms=10
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get

    pin2.set 0
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    pin1 = pin-factory.pin pin1-id --input --output --open-drain --pull-up
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

    pin1.set 0
    pin2.set 0

    pin2 = pin-factory.pin pin2-id --input --pull-up
    pin1 = pin-factory.pin pin1-id --output --value=1
    expect-equals 1 pin2.get

    pin1 = pin-factory.pin pin1-id --output --value=0
    expect-equals 0 pin2.get

    // Switching from input to output must not go through GND.
    pin1 = pin-factory.pin pin1-id --input

    ready-latch := monitor.Latch
    saw-0 := false
    t := task::
      ready-latch.set true
      pin2.wait-for 0
      saw-0 = true

    ready-latch.get
    pin1 = pin-factory.pin pin1-id --output --value=1
    sleep --ms=10
    expect-not saw-0

    pin1.set 0
    while not saw-0:
      yield
