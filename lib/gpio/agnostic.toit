// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import gpio

/**
Support for General Purpose Input/Output (GPIO) Pins that are agnostic to their wiring.

The $Pin represents a pin that is agnostic to how it is wired up.

The $Agnostic is an implementation of $Pin.
*/

/**
A $Pin that is agnostic to it wiring.

Call $on to activate the pin and $off to deactivate the pin.
*/
interface Pin:
  on -> none
  off -> none

/**
A pin that is agnostic to active high and active low.

The pin is configured on construction to be either active low, active high or open drain and acts accordingly.
*/
class Agnostic implements Pin:
  static MODE_ACTIVE_LOW/int  ::= 0
  static MODE_ACTIVE_HIGH/int ::= 1
  static MODE_OPEN_DRAIN/int  ::= 2

  pin/gpio.Pin
  on_delay/Duration?
  off_delay/Duration?

  on_value_/int
  off_value_/int

  /**
  Constructs an agnostic pin.

  The on/off delay should be less than 100ms.
  */
  constructor name .pin --mode/int=MODE_ACTIVE_HIGH --.on_delay=null --.off_delay=null --parents=[]:
    active := mode == MODE_ACTIVE_HIGH ? 1 : 0
    on_value_ = active
    off_value_ = 1 - active
    pin.config --output --open_drain=(mode == MODE_OPEN_DRAIN)
    pin.set off_value_

  /** See $Pin.on */
  on:
    pin.set on_value_
    if on_delay: sleep on_delay

  /** See $Pin.off */
  off:
    pin.set off_value_
    if off_delay: sleep off_delay
