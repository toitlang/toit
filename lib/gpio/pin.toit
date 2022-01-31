// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

/**
Support for General Purpose Input/Output (GPIO) Pins.

The $Pin represents actual physical pins.

The $VirtualPin is a software pin which can be used for actual pins that have
  different modes depending on whether they are used for input or output or
  peripherals simulated in software.
*/

/**
A General Purpose Input/Output (GPIO) Pin.

The Pin can be either in output or input mode, allowing for setting or reading
  the level.

Only one $Pin instance of any given GPIO number can be open at any given point
  in time. This is a system wide restriction.
To release the resources associated with the $Pin, call $Pin.close.
*/
class Pin:
  static GPIO_STATE_DOWN_ ::= 1
  static GPIO_STATE_UP_   ::= 2

  static resource_group_ ::= gpio_init_

  /**
  The numeric $Pin number.
  */
  num/int

  pull_up_/bool ::= false
  pull_down_/bool ::= false
  resource_/ByteArray? := null
  state_/monitor.ResourceState_? ::= null
  last_set_/int := 0

  /**
  Opens a GPIO Pin $num in input mode.

  While the Pin is in input mode, $pull_up and $pull_down resistors are applied as
    configured.
  */
  constructor.in num/int --pull_up/bool=false --pull_down/bool=false:
    return Pin num --input --pull_up=pull_up --pull_down=pull_down

  /**
  Opens a GPIO Pin $num in output mode.

  Use $Pin.set to set the output value. The default value is 0.
  */
  constructor.out num/int:
    return Pin num --output

  /**
  Opens a GPIO Pin on $num in a custom mode.

  If the Pin is to be used by another peripheral, both $input and $output can be
    left as `false`.
  */
  constructor .num --input/bool=false --output/bool=false --pull_up/bool=false --pull_down/bool=false:
    pull_up_ = pull_up
    pull_down_ = pull_down
    resource_ = gpio_use_ resource_group_ num
    // TODO(anders): Ideally we would create this resource ad-hoc, in input-mode.
    state_ = monitor.ResourceState_ resource_group_ resource_
    if input or output: config --input=input --output=output

  constructor.virtual_:
    num = -1

  /**
  Closes the pin and releases resources associated with it.
  */
  close:
    if resource_:
      state_.dispose
      gpio_unuse_ resource_group_ resource_
      resource_ = null

  /**
  Changes the configuration of this pin.

  If $open_drain is true, the output configuration will use
    - pull-low for 0
    - open-drain for 1
  */
  config --input/bool=false --output/bool=false --open_drain/bool=false:
    if open_drain and not output: throw "INVALID_ARGUMENT"
    gpio_config_ num (input and pull_up_) (input and pull_down_) input output open_drain

  /**
  Gets the value of the pin.
  It is an error to call this function when the pin is not configured to be an input.
  */
  get -> int:
    return gpio_get_ num

  /**
  Sets the value of the output-configured Pin.
  */
  set value/int:
    last_set_ = value
    gpio_set_ num value

  /**
  Calls the given $block on each edge on the Pin.

  An edge means a transition from high to low, or low to high.
  */
  do [block]:
    expected := get ^ 1
    while true:
      wait_for expected
      block.call expected
      expected ^= 1

  /**
  Blocks until the Pin reads the value configured.

  Use $with_timeout to automatically abort the operation after a fixed amount
   of time.
  */
  wait_for value -> none:
    gpio_config_interrupt_ num true
    try:
      if get == value: return
      expected_state := value == 1 ? GPIO_STATE_UP_ : GPIO_STATE_DOWN_
      state := state_.wait_for_state expected_state
      state_.clear_state expected_state
      return
    finally:
      gpio_config_interrupt_ num false

/**
Virtual pin.

The functionality of this pin is set in $VirtualPin. When $set is called, it
  calls the lambda given in the constructor with the argument given to $set.
*/
class VirtualPin extends Pin:
  set_/Lambda ::= ?

  /**
  Constructs a virtual pin with the given $set_ lambda functionality.
  */
  constructor .set_:
    super.virtual_

  /** Sets the $value by calling the lambda given in $Pin with the $value. */
  set value:
    set_.call value

  /** Closes the pin. */
  close:

  /** Does nothing. */
  config --input/bool=false --output/bool=false --open_drain/bool=false:

  /** Not supported. */
  get: throw "UNSUPPORTED"

  /** Not supported. */
  do [block]: throw "UNSUPPORTED"

  /** Not supported. */
  wait_for value: throw "UNSUPPORTED"

  /** Not supported. */
  num: throw "UNSUPPORTED"

/**
A pin that does the opposite of the physical pin that it takes in the constructor.
*/
class InvertedPin extends Pin:
  original_pin_ /Pin

  constructor .original_pin_:
    super.virtual_

  /** Sets the physical pin to 1 if $value is 0, and vice versa. */
  set value -> none:
    original_pin_.set 1 - value

  close -> none:
    original_pin_.close

  /** Configures the underlying pin. */
  config --input/bool=false --output/bool=false --open_drain/bool=false -> none:
    original_pin_.config --input=input --output=output --open_drain=open_drain

  /** Returns 1 if the physical pin is at 0, and vice versa. */
  get -> int:
    return 1 - original_pin_.get

  /** Waits for 1 on on the physical pin if $value is 0, and vice versa. */
  wait_for value/int -> none:
    original_pin_.wait_for 1 - value

  num -> int:
    return original_pin_.num

gpio_init_:
  #primitive.gpio.init

gpio_use_ resource_group num:
  #primitive.gpio.use

gpio_unuse_ resource_group num:
  #primitive.gpio.unuse

gpio_config_ num pull_up pull_down input output open_drain:
  #primitive.gpio.config

gpio_get_ num:
  #primitive.gpio.get

gpio_set_ num value:
  #primitive.gpio.set

gpio_config_interrupt_ num enabled/bool:
  #primitive.gpio.config_interrupt
