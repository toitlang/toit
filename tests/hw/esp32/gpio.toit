// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests gpio pins.

Setup:
Connect pin 18 to pin 19, optionally with a 330 Ohm resistor to avoid short circuits.
*/

import gpio
import expect show *

import ..shared.gpio as shared

RESTRICTED ::= 7
PIN1 ::= 18
PIN2 ::= 19

class PinFactory implements shared.PinFactory:
  pin1/gpio.Pin? := null
  pin2/gpio.Pin? := null

  use-constructor/bool := false

  pin -> gpio.Pin
      pin-identifier/int
      --input/bool=false
      --output/bool=false
      --pull-down/bool=false
      --pull-up/bool=false
      --open-drain/bool=false
      --value/int?=null:
    if use-constructor:
      if pin-identifier == PIN1:
        if pin1: pin1.close
      else:
        if pin2: pin2.close
      pin := gpio.Pin pin-identifier
          --input=input
          --output=output
          --pull-down=pull-down
          --pull-up=pull-up
          --open-drain=open-drain
          --value=value
      if pin-identifier == PIN1:
        pin1 = pin
      else:
        pin2 = pin
      return pin

    pin/gpio.Pin := pin-identifier == PIN1 ? pin1 : pin2
    pin.configure
        --input=input
        --output=output
        --pull-down=pull-down
        --pull-up=pull-up
        --open-drain=open-drain
        --value=value
    return pin

  close:
    if pin1: pin1.close
    if pin2: pin2.close

main:
  expect-throw "RESTRICTED_PIN": gpio.Pin RESTRICTED
  pin1 := gpio.Pin PIN1
  pin2 := gpio.Pin PIN2

  expect-throw "ALREADY_IN_USE": gpio.Pin PIN1
  expect-throw "ALREADY_IN_USE": gpio.Pin PIN2

  // Test that we can close a pin and open it again.
  pin1.close
  pin2.close

  pin-factory := PinFactory
  shared.test-configurations pin-factory PIN1 PIN2

  pin-factory.close

  print "ALL TESTS PASSED"
