// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor
import system

/**
Support for General Purpose Input/Output (GPIO) pins.

The $Pin represents actual physical pins.

The $VirtualPin is a software pin which can be used for actual pins that have
  different modes depending on whether they are used for input or output or
  peripherals simulated in software.
*/

/**
A General Purpose Input/Output (GPIO) pin.

The pin can be either in output or input mode, allowing for setting or reading
  the level.

Only one $Pin instance of any given GPIO number can be open at any given point
  in time. This is a system wide restriction.
To release the resources associated with the $Pin, call $Pin.close.
*/
class Pin:
  static GPIO-STATE-EDGE-TRIGGERED_ ::= 1

  static resource-group_ ::= gpio-init_

  /**
  The numeric $Pin number.
  */
  num/int

  // Pull up and pull down are only kept for the deprecated function $config.
  pull-up_/bool := false
  pull-down_/bool := false
  resource_/ByteArray? := null
  state_/monitor.ResourceState_? ::= null
  last-set_/int := 0

  /**
  Opens a GPIO pin $num in input mode.

  While the pin is in input mode, $pull-up and $pull-down resistors are applied as
    configured.

  See $constructor for more information.
  */
  constructor.in num/int
      --pull-up/bool=false
      --pull-down/bool=false
      --allow-restricted/bool=false:
    return Pin num --input --pull-up=pull-up --pull-down=pull-down

  /**
  Opens a GPIO pin $num in output mode.

  Use $Pin.set to set the output value. The default value is 0.

  See $constructor for more information.
  */
  constructor.out num/int --allow-restricted/bool=false:
    return Pin num --output

  /**
  Opens a GPIO pin on $num in a custom mode.

  If the pin is to be used by another peripheral, both $input and $output can be
    left as `false`. The library that uses the pin should call $configure with the
    configuration it needs.

  If a pin should be used both as $input and as an $output, $open-drain is often needed to
    avoid short-circuits. See $configure for more information.

  Some pins should usually not be used. For example, the ESP32 uses pins
    6-11 to communicate with flash and PSRAM. These pins can not be
    instantiated unless the $allow-restricted flag is set to true.

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
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --allow-restricted/bool=false:
    pull-up_ = pull-up
    pull-down_ = pull-down
    resource_ = gpio-use_ resource-group_ num allow-restricted
    // TODO(anders): Ideally we would create this resource ad-hoc, in input-mode.
    state_ = monitor.ResourceState_ resource-group_ resource_
    if input or output:
      try:
        configure
            --input=input
            --output=output
            --pull-down=pull-down
            --pull-up=pull-up
            --open-drain=open-drain
      finally: | is-exception _ |
        if is-exception: close

  /**
  Opens a GPIO pin on the chip identified by the given $path and $num (often called "offset").

  This constructor only works on Linux.

  See $(constructor num) for more information on the remaining parameters.
  */
  constructor.linux num/int
      --path/string
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --initial-value/int=0:
    chip := Chip path
    try:
      return Pin.linux num
          --chip=chip
          --input=input
          --output=output
          --pull-up=pull-up
          --pull-down=pull-down
          --open-drain=open-drain
          --initial-value=initial-value
    finally:
      chip.close

  /**
  Opens a GPIO pin on the given $chip and $num (often called "offset").

  This constructor only works on Linux.

  See $(constructor num) for more information on the remaining parameters.
  */
  constructor.linux num/int
      --chip/Chip
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --initial-value/int=0:
    return PinLinux_ num
        --chip=chip
        --input=input
        --output=output
        --pull-up=pull-up
        --pull-down=pull-down
        --open-drain=open-drain
        --initial-value=initial-value

  /**
  Opens a GPIO pin based on the given $name.

  This constructor only works on Linux.

  If a path to a chip is provided, finds the pin on that chip. Otherwise, searches
    all available chips (see $Chip.list).
  Names are not guaranteed to be unique. If multiple pins have the same name, the
    first pin found is returned.

  See $(constructor num) for more information on the remaining parameters.
  */
  constructor.linux
      --name/string
      --path/string?=null
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --initial-value/int=0:

    try-chip := : | path/string |
      chip := Chip path
      try:
        offset := gpio-linux-chip-offset-for-name_ chip.resource_ name
        if offset != -1:
          return Pin.linux offset
              --chip=chip
              --input=input
              --output=output
              --pull-up=pull-up
              --pull-down=pull-down
              --open-drain=open-drain
              --initial-value=initial-value
      finally:
        chip.close

    if path:
      try-chip.call path
    else:
      Chip.list.do try-chip
    throw "NOT_FOUND"

  /**
  Opens a GPIO pin based on the given $name on the given $chip.

  This constructor only works on Linux.

  If a chip is provided, finds the pin on that chip. Otherwise, searches all available
    chips (see $Chip.list).
  Names are not guaranteed to be unique. If multiple pins have the same name, the
    first pin found is returned.

  See $(constructor num) for more information on the remaining parameters.
  */
  constructor.linux
      --name/string
      --chip/Chip
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --initial-value/int=0:

    offset := gpio-linux-chip-offset-for-name_ chip.resource_ name
    if offset < 0: throw "NOT_FOUND"
    return Pin.linux offset
        --chip=chip
        --input=input
        --output=output
        --pull-up=pull-up
        --pull-down=pull-down
        --open-drain=open-drain
        --initial-value=initial-value

  constructor.internal_ .num:

  /**
  Closes the pin and releases resources associated with it.
  */
  close:
    if not resource_: return
    critical-do:
      state_.dispose
      gpio-unuse_ resource-group_ resource_
      resource_ = null

  /**
  Changes the configuration of this pin.

  If $open-drain is true, the output configuration will use
    - pull-low for 0
    - open-drain for 1

  Deprecated. Use $configure instead. Note that $configure behaves differently than
    $config when a pin was initialized with a pull-up or pull-down resistor. This function
    ($config) maintains the pull-up/pull-down configuration of the pin. However, $configure
    resets that configuration.
  */
  // When removing this function, it's safe to remove `pull-down_` and `pull-up_` as well.
  config --input/bool=false --output/bool=false --open-drain/bool=false:
    if open-drain and not output: throw "INVALID_ARGUMENT"
    gpio-config_ num (input and pull-up_) (input and pull-down_) input output open-drain

  /**
  Changes the configuration of this pin.

  If $input is true, the pin is configured as an input.
  If $output is true, the pin is configured as an output. If $open-drain is set, then the pin
    value is set to 1 (not pulling to ground). Otherwise the pin outputs 0.

  It is safe to use a pin as $input and $output at the same time, but typically this
    requires the $open-drain flag.

  If a pin is used as $input and $output without $open-drain, then the
    pin can only read the value that was set with $set. It can/should not read a
    value that was set by the outside. In fact, doing so could damage the microcontroller, as
    the external device would need to short circuit the pin.

  If a pin is configured to be an input, it can have a $pull-up or $pull-down.

  If $open-drain is set, then the pin can only pull the pin to the ground. Together, with
    a $pull-up resistor this still allows the pin to emit both 0 and 1. In this configuration,
    connected devices can also safely pull the pin to ground without damaging the microcontroller.
    This configuration is typically used in communications that only use one data bus for
    input and output, such as the DHT11/DHT22, the i2c bus, and the one-wire bus. Note, that
    the corresponding libraries (like the i2c library) already take care of setting this
    configuration for you.
  Note that it is not safe to ground an $open-drain pin and to connect it externally to VCC.
  Also note, that only one entity on an open-drain bus needs to pull the bus high. As such,
    it can be useful to set $open-drain without $pull-up.
  */
  configure
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false:
    if open-drain and not output: throw "INVALID_ARGUMENT"
    if pull-up and not input: throw "INVALID_ARGUMENT"
    if pull-down and not input: throw "INVALID_ARGUMENT"
    if pull-up and output and not open-drain: throw "INVALID_ARGUMENT"
    if pull-down and output: throw "INVALID_ARGUMENT"
    if pull-down and pull-up: throw "INVALID_ARGUMENT"
    pull-down_ = pull-down
    pull-up_ = pull-up
    gpio-config_ num pull-up pull-down input output open-drain

  /**
  Gets the value of the pin.
  It is an error to call this function when the pin is not configured to be an input.
  */
  get -> int:
    return gpio-get_ num

  /**
  Sets the value of the output-configured pin.
  */
  set value/int:
    last-set_ = value
    gpio-set_ num value

  /**
  Calls the given $block on each edge on the pin.

  An edge means a transition from high to low, or low to high.
  */
  do [block]:
    expected := get ^ 1
    while true:
      wait-for expected
      block.call expected
      expected ^= 1

  /**
  Blocks until the pin reads the requested $value.

  Use $with-timeout to automatically abort the operation after a fixed amount
    of time.
  */
  wait-for value -> none:
    if get == value: return
    state_.clear-state GPIO-STATE-EDGE-TRIGGERED_
    config-timestamp := gpio-config-interrupt_ resource_ true
    try:
      // Make sure the pin didn't change to the expected value while we
      // were setting up the interrupt.
      if get == value: return

      while true:
        state_.wait-for-state GPIO-STATE-EDGE-TRIGGERED_
        if not resource_:
          // The pin was closed while we were waiting.
          return
        event-timestamp := gpio-last-edge-trigger-timestamp_ resource_
        // If there was an edge transition after we configured the interrupt,
        // we are guaranteed that we have seen the value we are waiting for.
        // The pin's value might already be different now, but we know
        // that it was at the correct value at least for a brief period of
        // time when the interrupt triggered.
        if (event-timestamp - config-timestamp).abs < 0xFF_FFFF:
          if event-timestamp >= config-timestamp: return
        else:
          // Unrealistically far from each other.
          // Assume an overflow happened (either the event or config timestamp).
          if event-timestamp < config-timestamp: return
        state_.clear-state GPIO-STATE-EDGE-TRIGGERED_
        // The following test shouldn't be necessary, but doesn't hurt either.
        if get == value: return
    finally:
      if resource_:
        gpio-config-interrupt_ resource_ false

  /**
  Sets the open-drain property of this pin.

  This is a low-level function that doesn't affect any other configuration
    of the pin.
  */
  set-open-drain value/bool:
    gpio-set-open-drain_ num value


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
    super.internal_ -1

  /** Sets the $value by calling the lambda that was given during construction with $value. */
  set value:
    set_.call value

  /** Closes the pin. */
  close:

  /**
  Does nothing.
  Deprecated. Use $configure instead.
  */
  config --input/bool=false --output/bool=false --open-drain/bool=false:

  /** Does nothing. */
  configure
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false:

  /** Not supported. */
  get: throw "UNSUPPORTED"

  /** Not supported. */
  do [block]: throw "UNSUPPORTED"

  /** Not supported. */
  wait-for value: throw "UNSUPPORTED"

  /** Not supported. */
  num: throw "UNSUPPORTED"

  /** Not supported. */
  set-open-drain value/bool: throw "UNSUPPORTED"


/**
A pin that does the opposite of the physical pin that it takes in the constructor.
*/
class InvertedPin extends Pin:
  original-pin_ /Pin

  constructor .original-pin_:
    super.internal_ -1

  /** Sets the physical pin to 1 if $value is 0, and vice versa. */
  set value -> none:
    original-pin_.set 1 - value

  close -> none:
    original-pin_.close

  /** Configures the underlying pin. */
  config --input/bool=false --output/bool=false --open-drain/bool=false -> none:
    // Avoid warning of call to deprecated method by casting to 'any'.
    (original-pin_ as any).config --input=input --output=output --open-drain=open-drain

  configure
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false:
    original-pin_.configure --input=input --output=output --pull-up=pull-up --pull-down=pull-down --open-drain=open-drain

  /** Returns 1 if the physical pin is at 0, and vice versa. */
  get -> int:
    return 1 - original-pin_.get

  /** Waits for 1 on on the physical pin if $value is 0, and vice versa. */
  wait-for value/int -> none:
    original-pin_.wait-for 1 - value

  num -> int:
    return original-pin_.num

  set-open-drain value/bool:
    original-pin_.set-open-drain value

/**
A GPIO chip on Linux.
*/
class Chip:
  static resource-group_ ::= gpio-linux-chip-init_

  /**
  The path to the GPIO chip.
  */
  path/string
  resource_/ByteArray? := ?
  name_/string? := null
  label_/string? := null
  line-count_/int? := null

  constructor .path:
    resource_ = gpio-linux-chip-new_ resource-group_ path
    add-finalizer this:: close

  /**
  Lists all GPIO chips on the system.

  The returned list contains paths to the GPIO chips.
  */
  static list -> List:
    return gpio-linux-list-chips_

  /** The name of the GPIO chip. */
  name -> string:
    if not name_: fetch-info_
    return name_

  /** The label of the GPIO chip. */
  label -> string:
    if not label_: fetch-info_
    return label_

  /** The number of pins on the GPIO chip. */
  pin-count -> int:
    if not line-count_: fetch-info_
    return line-count_

  fetch-info_ -> none:
    info/List := gpio-linux-chip-info_ resource_
    name_ = info[0]
    label_ = info[1]
    line-count_ = info[2]

  pin-names -> List:
    return List pin-count:
      info := gpio-linux-chip-pin-info_ resource_ it
      info[0]

  /**
  Closes the chip.

  If children (like pins) are still open, the closing of the chip is delayed
    until all children are closed.
  */
  close:
    if resource_:
      resource := resource_
      resource_ = null
      remove-finalizer this
      gpio-linux-chip-close_ resource

class PinLinux_ extends Pin:
  static resource-group_ ::= gpio-linux-pin-init_

  constructor
      offset/int
      --chip/Chip
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --initial-value/int=0:
    super.internal_ offset
    resource_ = gpio-linux-pin-new_
        resource-group_
        chip.resource_
        offset
        pull-up
        pull-down
        input
        output
        open-drain
        initial-value
    add-finalizer this:: close

  close -> none:
    if resource_:
      resource := resource_
      resource_ = null
      remove-finalizer this
      gpio-linux-pin-close_ resource

  configure
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --value/int=0:
    gpio-linux-pin-configure_ resource_ pull-up pull-down input output open-drain value

  get -> int:
    return gpio-linux-pin-get_ resource_

  set value -> none:
    if not 0 <= value <= 1: throw "INVALID_ARGUMENT"
    gpio-linux-pin-set_ resource_ value

  /** Waits for 1 on on the physical pin if $value is 0, and vice versa. */
  wait-for value/int -> none:
    throw "UNIMPLEMENTED"

  set-open-drain value/bool:
    gpio-linux-pin-set-open-drain_ resource_ value


gpio-init_:
  #primitive.gpio.init

gpio-use_ resource-group num allow-restricted:
  #primitive.gpio.use:
    if it == "PERMISSION_DENIED":
      throw "RESTRICTED_PIN"
    throw it

gpio-unuse_ resource-group num:
  #primitive.gpio.unuse

gpio-config_ num pull-up pull-down input output open-drain:
  #primitive.gpio.config

gpio-get_ num:
  #primitive.gpio.get

gpio-set_ num value:
  #primitive.gpio.set

gpio-config-interrupt_ resource enabled/bool:
  #primitive.gpio.config-interrupt

gpio-last-edge-trigger-timestamp_ resource:
  #primitive.gpio.last-edge-trigger-timestamp

gpio-set-open-drain_ num value/bool:
  #primitive.gpio.set-open-drain

gpio-linux-list-chips_ -> List:
  #primitive.gpio-linux.list-chips

gpio-linux-chip-init_:
  #primitive.gpio-linux.chip-init

gpio-linux-chip-new_ resource-group path:
  #primitive.gpio-linux.chip-new

gpio-linux-chip-close_ resource:
  #primitive.gpio-linux.chip-close

gpio-linux-chip-info_ resource -> List:
  #primitive.gpio-linux.chip-info

gpio-linux-chip-pin-info_ chip-resource offset -> List:
  #primitive.gpio-linux.chip-pin-info

gpio-linux-chip-offset-for-name_ chip-resource name -> int:
  #primitive.gpio-linux.chip-pin-offset-for-name

gpio-linux-pin-init_:
  #primitive.gpio-linux.pin-init

gpio-linux-pin-new_ resource-group chip offset pull-up pull-down input output open-drain initial-value:
  #primitive.gpio-linux.pin-new

gpio-linux-pin-close_ resource:
  #primitive.gpio-linux.pin-close

gpio-linux-pin-configure_ resource pull-up pull-down input output open-drain initial-value:
  #primitive.gpio-linux.pin-configure

gpio-linux-pin-get_ resource:
  #primitive.gpio-linux.pin-get

gpio-linux-pin-set_ resource value:
  #primitive.gpio-linux.pin-set

gpio-linux-pin-set-open-drain_ resource value:
  #primitive.gpio-linux.pin-set-open-drain
