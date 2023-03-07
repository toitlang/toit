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

PIN1 ::= 18
PIN2 ::= 19

main:
  pin1 := gpio.Pin PIN1
  pin2 := gpio.Pin PIN2

  // Test that we can close a pin and open it again.
  pin1.close
  pin2.close

  pin1 = gpio.Pin PIN1
  pin2 = gpio.Pin PIN2

  // Test pin configurations.

  2.repeat: | i |
    should_use_constructor := (i == 1)
    print "Using constructors: $should_use_constructor"

    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --output
      pin2.close
      pin2 = gpio.Pin PIN2 --input
    else:
      pin1.configure --output
      pin2.configure --input

    expect_equals 0 pin2.get
    pin1.set 1
    expect_equals 1 pin2.get

    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull_down
    else:
      pin1.configure --input --pull_down
    expect_equals 0 pin1.get
    expect_equals 0 pin2.get

    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull_up
    else:
      pin1.configure --input --pull_up
    expect_equals 1 pin1.get
    expect_equals 1 pin2.get

    // Try the pull-down/pull-up again to ensure that we weren't just lucky.
    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull_down
    else:
      pin1.configure --input --pull_down
    expect_equals 0 pin1.get
    expect_equals 0 pin2.get

    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull_up
    else:
      pin1.configure --input --pull_up
    expect_equals 1 pin1.get
    expect_equals 1 pin2.get

    if should_use_constructor:
      pin1.close
      expect_throw "INVALID_ARGUMENT": pin1 = gpio.Pin PIN1 --input --pull_up --pull_down
      expect_throw "INVALID_ARGUMENT": pin1 = gpio.Pin PIN1 --output --pull_up --pull_down
      pin1 = gpio.Pin PIN1
    else:
      expect_throw "INVALID_ARGUMENT": pin1.configure --input --pull_up --pull_down
      expect_throw "INVALID_ARGUMENT": pin1.configure --output --pull_up --pull_down

    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull_up
      pin2.close
      pin2 = gpio.Pin PIN2 --output
    else:
      pin1.configure --input --pull_up
      pin2.configure --output

    // Override the pull up of pin1
    pin2.set 0
    expect_equals 0 pin1.get
    pin2.set 1
    expect_equals 1 pin1.get

    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull_down
      pin2.close
      pin2 = gpio.Pin PIN2 --output
    else:
      pin1.configure --input --pull_down
      pin2.configure --output
    pin2.set 0
    expect_equals 0 pin1.get
    // Override the pull down of pin1
    pin2.set 1
    expect_equals 1 pin1.get

    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull_up
      pin2.close
      pin2 = gpio.Pin PIN2 --output --open_drain
    else:
      pin1.configure --input --pull_up
      pin2.configure --output --open_drain

    pin2.set 1
    expect_equals 1 pin1.get
    // Since pin2 is output only, we can't ask for its value.

    pin2.set 0
    expect_equals 0 pin1.get

    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --pull_up
      pin2.close
      pin2 = gpio.Pin PIN2 --input --output --open_drain
    else:
      pin1.configure --input --pull_up
      pin2.configure --input --output --open_drain

    pin2.set 1
    expect_equals 1 pin1.get
    expect_equals 1 pin2.get

    pin2.set 0
    expect_equals 0 pin1.get
    expect_equals 0 pin2.get

    if should_use_constructor:
      pin1.close
      pin1 = gpio.Pin PIN1 --input --output --open_drain --pull_up
    else:
      pin1.configure --input --output --open_drain --pull_up

    pin1.set 0
    pin2.set 0
    expect_equals 0 pin1.get
    expect_equals 0 pin2.get

    pin1.set 1
    pin2.set 0
    expect_equals 0 pin1.get
    expect_equals 0 pin2.get

    pin1.set 0
    pin2.set 1
    expect_equals 0 pin1.get
    expect_equals 0 pin2.get

    pin1.set 1
    pin2.set 1
    expect_equals 1 pin1.get
    expect_equals 1 pin2.get

  pin1.close
  pin2.close

  print "done"
