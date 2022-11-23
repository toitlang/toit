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
  static GPIO_STATE_EDGE_TRIGGERED_ ::= 1

  static resource_group_ ::= gpio_init_

  /**
  The numeric $Pin number.
  */
  num/int

  // Pull up and pull down are only kept for the deprecated function $config.
  pull_up_/bool := false
  pull_down_/bool := false
  resource_/ByteArray? := null
  state_/monitor.ResourceState_? ::= null
  last_set_/int := 0

  /**
  Opens a GPIO Pin $num in input mode.

  While the Pin is in input mode, $pull_up and $pull_down resistors are applied as
    configured.

  See $constructor for more information.
  */
  constructor.in num/int
      --pull_up/bool=false
      --pull_down/bool=false
      --allow_restricted/bool=false:
    return Pin num --input --pull_up=pull_up --pull_down=pull_down

  /**
  Opens a GPIO Pin $num in output mode.

  Use $Pin.set to set the output value. The default value is 0.

  See $constructor for more information.
  */
  constructor.out num/int --allow_restricted/bool=false:
    return Pin num --output

  /**
  Opens a GPIO Pin on $num in a custom mode.

  If the Pin is to be used by another peripheral, both $input and $output can be
    left as `false`. The library that uses the pin should call $configure with the
    configuration it needs.

  If a pin should be used both as $input and as an $output, $open_drain is often needed to
    avoid short-circuits. See $configure for more information.

  Some pins should usually not be used. For example, the ESP32 uses pins
    6-11 to communicate with flash and PSRAM. These pins can not be
    instantiated unless the $allow_restricted flag is set to `true`.

  # ESP32
  The ESP32 has 34 physical pins (0-19, 21-23, 25-27, and 32-39). Each pin can
    be used as general-purpose pin, or be connected to a peripheral.
  Pins 0, 2, 5, 12 and 15 are strapping pins.
  Pins 6-11 are normally connected to flash/PSRAM, and should not be used.
  Pins 12-15 are JTAG pins, and should not be used if JTAG support is needed.
  Pins 25-26 are DAC pins.
  Pins 34-39 are input only.
  Pins 32-39 are ADC pins of channel 1.
  Pins 0, 2, 4, 12-15, 25-27 are ADC pins of channel 2. ADC channel 2 has
    restrictions and should be avoided if possible.
  Pins 0, 2, 4, 12-16, 25-39 are RTC pins. They can be used in deep sleep. For
    example, to wake up from deep sleep.

  # ESP32C3
  The ESP32C3 has 22 physical pins (0-21). Each pin can be used as
    general-purpose pin, or be connected to a peripheral.

  Pins 2, 8, and 9 are strapping pins.
  Pins 12-17 are normally connected to flash/PSRAM, and should not be used.
  Pins 18-19 are JTAG pins, and should not be used if JTAG support is needed.
  Pins 0-5 are RTC pins and can be used in deep-sleep.
  Pins 0-4 are ADC pins of channel 1.
  Pin 5 is an ADC pin of channel 2. ADC channel 2 has restrictions and should be
    avoided if possible.

  # ESP32S3
  The ESP32S3 has 45 physical pins (0-21, 26-48). Each pin can be used as
    general-purpose pin, or be connected to a peripheral.

  Pins 0, 3, 45, and 46 are strapping pins.
  Pins 26-32 are normally connected to flash/PSRAM, and should not be used.
  Pins 33-37 are used when using octal flash or PSRAM. They may be available
    depending on the configuration, but are considered restricted.
  Pins 19-20 are JTAG pins, and should not be used if JTAG support is needed.
  Pins 1-10 are ADC pins of channel 1.
  Pins 11-20 are ADC pins of channel 2. ADC channel 2 has restrictions and
    should be avoided if possible.
  Pins 0-21 are RTC pins and can be used in deep-sleep.
  */
  constructor .num
      --input/bool=false
      --output/bool=false
      --pull_up/bool=false
      --pull_down/bool=false
      --open_drain/bool=false
      --allow_restricted/bool=false:
    pull_up_ = pull_up
    pull_down_ = pull_down
    resource_ = gpio_use_ resource_group_ num allow_restricted
    // TODO(anders): Ideally we would create this resource ad-hoc, in input-mode.
    state_ = monitor.ResourceState_ resource_group_ resource_
    if input or output:
      try:
        configure --input=input --output=output --pull_down=pull_down --pull_up=pull_up
      finally: | is_exception _ |
        if is_exception: close


  constructor.virtual_:
    num = -1

  /**
  Closes the pin and releases resources associated with it.
  */
  close:
    if not resource_: return
    critical_do:
      state_.dispose
      gpio_unuse_ resource_group_ resource_
      resource_ = null

  /**
  Changes the configuration of this pin.

  If $open_drain is true, the output configuration will use
    - pull-low for 0
    - open-drain for 1

  Deprecated. Use $configure instead. Note that $configure behaves differently than
    $config when a pin was initialized with a pull-up or pull-down resistor. This function
    ($config) maintains the pull-up/pull-down configuration of the pin. However, $configure
    resets that configuration.
  */
  // When removing this function, it's safe to remove `pull_down_` and `pull_up_` as well.
  config --input/bool=false --output/bool=false --open_drain/bool=false:
    if open_drain and not output: throw "INVALID_ARGUMENT"
    gpio_config_ num (input and pull_up_) (input and pull_down_) input output open_drain

  /**
  Changes the configuration of this pin.

  If $input is true, the pin is configured as an input.
  If $output is true, the pin is configured as an output. If $open_drain is set, then the pin
    value is set to 1 (not pulling to ground). Otherwise the pin outputs 0.

  It is safe to use a pin as $input and $output at the same time, but typically this
    requires the $open_drain flag.

  If a pin is used as $input and $output without $open_drain, then the
    pin can only read the value that was set with $set. It can/should not read a
    value that was set by the outside. In fact, doing so could damage the microcontroller, as
    the external device would need to short circuit the pin.

  If a pin is configured to be an input, it can have a $pull_up or $pull_down.

  If $open_drain is set, then the pin can only pull the pin to the ground. Together, with
    a $pull_up resistor this still allows the pin to emit both 0 and 1. In this configuration,
    connected devices can also safely pull the pin to ground without damaging the microcontroller.
    This configuration is typically used in communications that only use one data bus for
    input and output, such as the DHT11/DHT22, the i2c bus, and the one-wire bus. Note, that
    the corresponding libraries (like the i2c library) already take care of setting this
    configuration for you.
  Note that it is not safe to ground an $open_drain pin and to connect it externally to VCC.
  Also note, that only one entity on an open-drain bus needs to pull the bus high. As such,
    it can be useful to set $open_drain without $pull_up.
  */
  configure
      --input/bool=false
      --output/bool=false
      --pull_up/bool=false
      --pull_down/bool=false
      --open_drain/bool=false:
    if open_drain and not output: throw "INVALID_ARGUMENT"
    if pull_up and not input: throw "INVALID_ARGUMENT"
    if pull_down and not input: throw "INVALID_ARGUMENT"
    if pull_up and output and not open_drain: throw "INVALID_ARGUMENT"
    if pull_down and output: throw "INVALID_ARGUMENT"
    if pull_down and pull_up: throw "INVALID_ARGUMENT"
    pull_down_ = pull_down
    pull_up_ = pull_up
    gpio_config_ num pull_up pull_down input output open_drain

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
    if get == value: return
    state_.clear_state GPIO_STATE_EDGE_TRIGGERED_
    config_timestamp := gpio_config_interrupt_ resource_ true
    try:
      // Make sure the pin didn't change to the expected value while we
      // were setting up the interrupt.
      if get == value: return

      while true:
        state_.wait_for_state GPIO_STATE_EDGE_TRIGGERED_
        event_timestamp := gpio_last_edge_trigger_timestamp_ resource_
        // If there was an edge transition after we configured the interrupt,
        // we are guaranteed that we have seen the value we are waiting for.
        // The pin's value might already be different now, but we know
        // that it was at the correct value at least for a brief periood of
        // time when the interrupt triggered.
        if event_timestamp >= config_timestamp: return
        // The following test shouldn't be necessary, but doesn't hurt either.
        if get == value: return
    finally:
      gpio_config_interrupt_ resource_ false

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

  /**
  Does nothing.
  Deprecated. Use $configure instead.
  */
  config --input/bool=false --output/bool=false --open_drain/bool=false:

  /** Does nothing. */
  configure
      --input/bool=false
      --output/bool=false
      --pull_up/bool=false
      --pull_down/bool=false
      --open_drain/bool=false:

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
    // Avoid warning of call to deprecated method by casting to 'any'.
    (original_pin_ as any).config --input=input --output=output --open_drain=open_drain

  configure
      --input/bool=false
      --output/bool=false
      --pull_up/bool=false
      --pull_down/bool=false
      --open_drain/bool=false:
    original_pin_.configure --input=input --output=output --pull_up=pull_up --pull_down=pull_down --open_drain=open_drain

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

gpio_use_ resource_group num allow_restricted:
  #primitive.gpio.use

gpio_unuse_ resource_group num:
  #primitive.gpio.unuse

gpio_config_ num pull_up pull_down input output open_drain:
  #primitive.gpio.config

gpio_get_ num:
  #primitive.gpio.get

gpio_set_ num value:
  #primitive.gpio.set

gpio_config_interrupt_ resource enabled/bool:
  #primitive.gpio.config_interrupt

gpio_last_edge_trigger_timestamp_ resource:
  #primitive.gpio.last_edge_trigger_timestamp
