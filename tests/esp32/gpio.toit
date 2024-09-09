/*  */// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests gpio pins.

Setup:
Connect pin 18 to pin 19, optionally with a 330 Ohm resistor to avoid short circuits.
*/

import gpio
import expect show *

RESTRICTED ::= 7
PIN1 ::= 18
PIN2 ::= 19

main:
  expect-throw "RESTRICTED_PIN": gpio.Pin RESTRICTED
  pin1 := gpio.Pin PIN1
  pin2 := gpio.Pin PIN2

  // Test that we can close a pin and open it again.
  pin1.close
  pin2.close

  pin1 = gpio.Pin PIN1
  pin2 = gpio.Pin PIN2

  // Test pin configurations.

  2.repeat: | i |
    should-use-constructor := (i == 1)
    print "Using constructors: $should-use-constructor"

    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --output
      pin2.close
      pin2 = gpio.Pin PIN2 --input
    else:
      pin1.configure --output
      pin2.configure --input

    expect-equals 0 pin2.get
    pin1.set 1
    expect-equals 1 pin2.get

    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull-down
    else:
      pin1.configure --input --pull-down
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull-up
    else:
      pin1.configure --input --pull-up
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get

    // Try the pull-down/pull-up again to ensure that we weren't just lucky.
    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull-down
    else:
      pin1.configure --input --pull-down
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull-up
    else:
      pin1.configure --input --pull-up
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get

    if should-use-constructor:
      pin1.close
      expect-throw "INVALID_ARGUMENT": pin1 = gpio.Pin PIN1 --input --pull-up --pull-down
      expect-throw "INVALID_ARGUMENT": pin1 = gpio.Pin PIN1 --output --pull-up --pull-down
      pin1 = gpio.Pin PIN1
    else:
      expect-throw "INVALID_ARGUMENT": pin1.configure --input --pull-up --pull-down
      expect-throw "INVALID_ARGUMENT": pin1.configure --output --pull-up --pull-down

    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull-up
      pin2.close
      pin2 = gpio.Pin PIN2 --output
    else:
      pin1.configure --input --pull-up
      pin2.configure --output

    // Override the pull up of pin1
    pin2.set 0
    expect-equals 0 pin1.get
    pin2.set 1
    expect-equals 1 pin1.get

    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull-down
      pin2.close
      pin2 = gpio.Pin PIN2 --output
    else:
      pin1.configure --input --pull-down
      pin2.configure --output
    pin2.set 0
    expect-equals 0 pin1.get
    // Override the pull down of pin1
    pin2.set 1
    expect-equals 1 pin1.get

    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull-up
      pin2.close
      pin2 = gpio.Pin PIN2 --output --open-drain
    else:
      pin1.configure --input --pull-up
      pin2.configure --output --open-drain

    pin2.set 1
    expect-equals 1 pin1.get
    // Since pin2 is output only, we can't ask for its value.

    pin2.set 0
    expect-equals 0 pin1.get

    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull-up
      pin2.close
      pin2 = gpio.Pin PIN2 --input --output --open-drain
    else:
      pin1.configure --input --pull-up
      pin2.configure --input --output --open-drain

    pin2.set 1
    expect-equals 1 pin1.get
    expect-equals 1 pin2.get

    pin2.set 0
    expect-equals 0 pin1.get
    expect-equals 0 pin2.get

    if should-use-constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --output --open-drain --pull-up
    else:
      pin1.configure --input --output --open-drain --pull-up

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

  pin1.close
  pin2.close

  print "done"
