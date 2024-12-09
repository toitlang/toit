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
interface Pin:
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

  If the pin is configured as output, the initial value can be set with the
    $value parameter.

  # ESP32
  The ESP32 has 34 physical pins (0-19, 21-23, 25-27, and 32-39). Each pin can
    be used as a general-purpose pin, or be connected to a peripheral.
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
    a general-purpose pin, or be connected to a peripheral.

  Pins 2, 8, and 9 are strapping pins.
  Pins 12-17 are normally connected to flash/PSRAM, and should not be used.
  Pins 18-19 are JTAG pins, and should not be used if JTAG support is needed.
  Pins 0-5 are RTC pins and can be used in deep-sleep.
  Pins 0-4 are ADC pins of channel 1.
  Pin 5 is an ADC pin of channel 2. ADC channel 2 has restrictions and should be
    avoided if possible.

  # ESP23C6
  The ESP32C6 has 31 physical pins (0-30). Each pin can be used as
    a general-purpose pin, or be connected to a peripheral.

  Pins 4, 5, 8, 9, and 15 are strapping pins.
  Pins 24-30 are normally connected to flash/PSRAM, and should not be used.
  Pins 10-11 are not led out to any chip pins.
  Pins 12-13 are JTAG pins, and should not be used if JTAG support is needed.
  Pins 0-6 are ADC pins of channel 1.
  Pins 0-7 are RTC pins and can be used in deep-sleep.
  For chip variants without an in-package flash, GPIO14 is not led out to any
    chip pins.

  # ESP32S2
  The ESP32S2 has 43 physical pins (0-21, 26-46). Each pin can be used as
    a general-purpose pin, or be connected to a peripheral.

  Pins 0, 45, and 46 are strapping pins.
  Pins 26-32 are normally connected to flash/PSRAM, and should not be used.
  Pins 39-42 are JTAG pins, and should not be used if JTAG support is needed.
  Pins 1-10 are ADC pins of channel 1.
  Pins 11-20 are ADC pins of channel 2. ADC channel 2 has restrictions and
    should be avoided if possible.
  Pins 0-21 are RTC pins and can be used in deep-sleep.
  Pin 46 is fixed to pull-down and is input only.

  # ESP32S3
  The ESP32S3 has 45 physical pins (0-21, 26-48). Each pin can be used as
    a general-purpose pin, or be connected to a peripheral.

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
  constructor num/int
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --allow-restricted/bool=false
      --value/int=0:
    return Pin_ num
        --input=input
        --output=output
        --pull-up=pull-up
        --pull-down=pull-down
        --open-drain=open-drain
        --value=value

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
      --value/int=0:
    chip := Chip path
    try:
      return Pin.linux num
          --chip=chip
          --input=input
          --output=output
          --pull-up=pull-up
          --pull-down=pull-down
          --open-drain=open-drain
          --value=value
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
      --value/int=0:
    return PinLinux_ num
        --chip=chip
        --input=input
        --output=output
        --pull-up=pull-up
        --pull-down=pull-down
        --open-drain=open-drain
        --value=value

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
      --value/int=0:

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
              --value=value
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
      --value/int=0:

    offset := gpio-linux-chip-offset-for-name_ chip.resource_ name
    if offset < 0: throw "NOT_FOUND"
    return Pin.linux offset
        --chip=chip
        --input=input
        --output=output
        --pull-up=pull-up
        --pull-down=pull-down
        --open-drain=open-drain
        --value=value

  /**
  The number or offset of this pin.
  */
  num -> int

  /**
  Closes the pin and releases resources associated with it.
  */
  close

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
  config --input/bool=false --output/bool=false --open-drain/bool=false


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

  If the pin is configured as output, the value can be set with the $value parameter. The
    new value might be written *before* the configuration is changed. If the pin is configured
    from push-pull to open-drain care must be taken that the new value is not 1, thus
    potentially short-circuiting the pin if another device is pulling the line low. When
    switching from push-pull to open-drain it is thus recommended to go through a short
    period of high-impedance (input) mode to avoid this issue.

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
  configure -> none
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --value/int?=null

  /**
  Gets the value of the pin.
  It is an error to call this function when the pin is not configured to be an input.
  */
  get -> int

  /**
  Sets the value of the output-configured pin.
  */
  set value/int

  /**
  Calls the given $block on each edge on the pin.

  An edge means a transition from high to low, or low to high.
  */
  do [block]

  /**
  Blocks until the Pin reads the value configured.

  Use $with-timeout to automatically abort the operation after a fixed amount
    of time.
  */
  wait-for value -> none

  /**
  Sets the open-drain property of this pin.

  This is a low-level function that doesn't affect any other configuration
    of the pin.
  */
  set-open-drain value/bool

/**
A base class for pins.

Note that the $configure_ method is abstract and must be implemented by subclasses.
  It is not private but protected.
*/
abstract class PinBase implements Pin:
  num/int

  // Pull up and pull down are only kept for the deprecated function $config.
  pull-up_/bool := false
  pull-down_/bool := false

  constructor .num:

  abstract close

  /**
  An implementation of $Pin.configure.
  */
  abstract configure_ -> none
      --input/bool
      --output/bool
      --pull-up/bool
      --pull-down/bool
      --open-drain/bool
      --value/int?

  /**
  See $Pin.get.
  */
  abstract get -> int

  /**
  See $Pin.set.
  */
  abstract set value/int

  /**
  See $Pin.wait-for.
  */
  abstract wait-for value -> none

  /**
  See $Pin.set-open-drain.
  */
  abstract set-open-drain value/bool

  /**
  See $Pin.config.
  */
  // When removing this function, it's safe to remove `pull-down_` and `pull-up_` as well.
  config --input/bool=false --output/bool=false --open-drain/bool=false:
    if open-drain and not output: throw "INVALID_ARGUMENT"
    configure --input=input --output=output --pull-up=pull-up_ --pull-down=pull-down_ --open-drain=open-drain --value=0

  /**
  See $Pin.configure.
  */
  configure
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --value/int?=null:
    if open-drain and not output: throw "INVALID_ARGUMENT"
    if pull-up and not input: throw "INVALID_ARGUMENT"
    if pull-down and not input: throw "INVALID_ARGUMENT"
    if pull-up and output and not open-drain: throw "INVALID_ARGUMENT"
    if pull-down and output: throw "INVALID_ARGUMENT"
    if pull-down and pull-up: throw "INVALID_ARGUMENT"
    pull-down_ = pull-down
    pull-up_ = pull-up
    configure_
        --input=input
        --output=output
        --pull-down=pull-down
        --pull-up=pull-up
        --open-drain=open-drain
        --value=value

  /**
  See $Pin.do.
  */
  do [block]:
    expected := get ^ 1
    while true:
      wait-for expected
      block.call expected
      expected ^= 1


class Pin_ extends PinBase:
  static GPIO-STATE-EDGE-TRIGGERED_ ::= 1

  static resource-group_ ::= gpio-init_

  resource_/ByteArray? := null
  state_/monitor.ResourceState_? ::= null

  /**
  See $(Pin.constructor num).
  */
  constructor num/int
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --allow-restricted/bool=false
      --value/int=0:
    resource_ = gpio-use_ resource-group_ num allow-restricted
    // TODO(anders): Ideally we would create this resource ad-hoc, in input-mode.
    state_ = monitor.ResourceState_ resource-group_ resource_
    super num
    if input or output:
      try:
        configure
            --input=input
            --output=output
            --pull-down=pull-down
            --pull-up=pull-up
            --open-drain=open-drain
            --value=value
      finally: | is-exception _ |
        if is-exception: close

  /**
  See $Pin.close.
  */
  close:
    if not resource_: return
    critical-do:
      state_.dispose
      gpio-unuse_ resource-group_ resource_
      resource_ = null

  /**
  See $Pin.configure.
  */
  configure_ -> none
      --input/bool
      --output/bool
      --pull-up/bool
      --pull-down/bool
      --open-drain/bool
      --value/int?:
    if not value: value = -1
    gpio-config_ num pull-up pull-down input output open-drain value

  /**
  See $Pin.get.
  */
  get -> int:
    return gpio-get_ num

  /**
  See Pin.set.
  */
  set value/int:
    gpio-set_ num value

  /**
  See $Pin.wait-for.
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
  See $Pin.wait-for.
  */
  set-open-drain value/bool:
    gpio-set-open-drain_ num value


/**
Virtual pin.

The functionality of this pin is set in $VirtualPin. When $set is called, it
  calls the lambda given in the constructor with the argument given to $set.
*/
class VirtualPin extends PinBase:
  set_/Lambda ::= ?

  /**
  Constructs a virtual pin with the given $set_ lambda functionality.
  */
  constructor .set_:
    super -1

  /** Sets the $value by calling the lambda that was given during construction with $value. */
  set value:
    set_.call value

  /** Closes the pin. */
  close:

  /** Does nothing except for setting the $value. */
  configure_ -> none
      --input/bool
      --output/bool
      --pull-up/bool
      --pull-down/bool
      --open-drain/bool
      --value/int?:
    if value: set value

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
class InvertedPin extends PinBase:
  original-pin_ /Pin

  constructor .original-pin_:
    super original-pin_.num

  /** Sets the physical pin to 1 if $value is 0, and vice versa. */
  set value -> none:
    original-pin_.set 1 - value

  close -> none:
    original-pin_.close

  configure_ -> none
      --input/bool
      --output/bool
      --pull-up/bool
      --pull-down/bool
      --open-drain/bool
      --value/int?:
    original-pin_.configure
        --input=input
        --output=output
        --pull-up=pull-up
        --pull-down=pull-down
        --open-drain=open-drain
        --value=value ? (1 - value) : null

  /** Returns 1 if the physical pin is at 0, and vice versa. */
  get -> int:
    return 1 - original-pin_.get

  /** Waits for 1 on on the physical pin if $value is 0, and vice versa. */
  wait-for value/int -> none:
    original-pin_.wait-for (1 - value)

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

class PinLinux_ extends PinBase:
  static GPIO-STATE-EDGE-TRIGGERED_ ::= 1

  static resource-group_ ::= gpio-linux-pin-init_

  state_/monitor.ResourceState_?
  resource_/ByteArray? := ?

  constructor
      offset/int
      --chip/Chip
      --input/bool=false
      --output/bool=false
      --pull-up/bool=false
      --pull-down/bool=false
      --open-drain/bool=false
      --value/int=0:
    resource_ = gpio-linux-pin-new_
        resource-group_
        chip.resource_
        offset
        pull-up
        pull-down
        input
        output
        open-drain
        value
    state_ = monitor.ResourceState_ resource-group_ resource_
    super offset
    add-finalizer this:: close

  close -> none:
    if not resource_: return
    critical-do:
      resource := resource_
      resource_ = null
      remove-finalizer this
      state_.dispose
      gpio-linux-pin-close_ resource

  configure_ -> none
      --input/bool
      --output/bool
      --pull-up/bool
      --pull-down/bool
      --open-drain/bool
      --value/int?:
    if not value: value = -1
    gpio-linux-pin-configure_ resource_ pull-up pull-down input output open-drain value

  get -> int:
    return gpio-linux-pin-get_ resource_

  set value -> none:
    if not 0 <= value <= 1: throw "INVALID_ARGUMENT"
    gpio-linux-pin-set_ resource_ value

  /**
  Blocks until the pin reads the requested $value.

  Use $with-timeout to automatically abort the operation after a fixed amount
    of time.
  */
  wait-for value -> none:
    if get == value: return
    state_.clear-state GPIO-STATE-EDGE-TRIGGERED_
    config-timestamp := gpio-linux-pin-last-edge-trigger-timestamp_ resource_
    gpio-linux-pin-config-edge-detection_ resource_ true
    try:
      // Make sure the pin didn't change to the expected value while we
      // were setting up the interrupt.
      if get == value: return

      while true:
        state_.wait-for-state GPIO-STATE-EDGE-TRIGGERED_
        if not resource_:
          // The pin was closed while we were waiting.
          return
        // We need to consume the edge events to update the last edge trigger timestamp.
        gpio-linux-pin-consume-edge-events_ resource_
        event-timestamp := gpio-linux-pin-last-edge-trigger-timestamp_ resource_
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
        gpio-linux-pin-config-edge-detection_ resource_ false

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

gpio-config_ num pull-up pull-down input output open-drain value:
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

gpio-linux-pin-new_ resource-group chip offset pull-up pull-down input output open-drain value:
  #primitive.gpio-linux.pin-new

gpio-linux-pin-close_ resource:
  #primitive.gpio-linux.pin-close

gpio-linux-pin-configure_ resource pull-up pull-down input output open-drain value:
  #primitive.gpio-linux.pin-configure

gpio-linux-pin-get_ resource:
  #primitive.gpio-linux.pin-get

gpio-linux-pin-set_ resource value:
  #primitive.gpio-linux.pin-set

gpio-linux-pin-set-open-drain_ resource value:
  #primitive.gpio-linux.pin-set-open-drain

gpio-linux-pin-config-edge-detection_ resource enabled/bool:
  #primitive.gpio-linux.pin-config-edge-detection

gpio-linux-pin-consume-edge-events_ resource:
  #primitive.gpio-linux.pin-consume-edge-events

gpio-linux-pin-last-edge-trigger-timestamp_ resource:
  #primitive.gpio-linux.pin-last-edge-trigger-timestamp
