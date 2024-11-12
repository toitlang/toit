// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests gpio pins.

Setup:
Connect GPIO_TEST to GPIO_MEASURE, optionally with a 330 Ohm resistor to avoid short circuits.
*/

import gpio
import host.os
import expect show *

import ..shared.gpio as shared

class PinFactory implements shared.PinFactory:
  pin1/gpio.Pin? := null
  pin2/gpio.Pin? := null

  pin1-name/string
  pin2-name/string

  constructor --.pin1-name --.pin2-name:

  pin -> gpio.Pin
      pin-identifier/string
      --use-constructor/bool=false
      --input/bool=false
      --output/bool=false
      --pull-down/bool=false
      --pull-up/bool=false
      --open-drain/bool=false:
    if use-constructor:
      if pin-identifier == pin1-name:
        if pin1: pin1.close
      else:
        if pin2: pin2.close
      pin := gpio.Pin.linux
          --name=pin-identifier
          --input=input
          --output=output
          --pull-down=pull-down
          --pull-up=pull-up
          --open-drain=open-drain
      if pin-identifier == pin1-name:
        pin1 = pin
      else:
        pin2 = pin
      return pin

    pin/gpio.Pin := pin-identifier == pin1-name ? pin1 : pin2
    pin.configure
        --input=input
        --output=output
        --pull-down=pull-down
        --pull-up=pull-up
        --open-drain=open-drain
    return pin

  close:
    if pin1: pin1.close
    if pin2: pin2.close

main:
  PIN1-NAME ::= os.env.get "GPIO_PIN1"
  PIN2-NAME ::= os.env.get "GPIO_PIN2"

  pin1 := gpio.Pin.linux --name=PIN1-NAME
  pin2 := gpio.Pin.linux --name=PIN2-NAME

  expect-throw "ALREADY_IN_USE": gpio.Pin.linux --name=PIN1-NAME
  expect-throw "ALREADY_IN_USE": gpio.Pin.linux --name=PIN2-NAME

  // Test that we can close a pin and open it again.
  pin1.close
  pin2.close

  pin-factory := PinFactory --pin1-name=PIN1-NAME --pin2-name=PIN2-NAME
  shared.test-configurations pin-factory PIN1-NAME PIN2-NAME

  pin-factory.close

  print "ALL TESTS PASSED"
