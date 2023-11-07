// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .gpio

/**
Touch sensor support.

This library provides ways to use some GPIO pins as capacitive touch pads.

On the ESP32, pins 0, 2, 4, 12-15, 27, 32, 33 can be used as touch pads.

# Examples
```
import gpio
import gpio.touch show Touch

main:
  touch := Touch (gpio.Pin 32)
  print (touch.read --raw)
  touch.close
```

Use the $Touch.threshold (als settable during construction) to define at which level the
  touch pad should be considered "touched". Typically, a calibration round reads the
  touch pad value (multiple times) when the program starts and sets the threshold to 2/3 of
  the average value.

A touch pad can be used to wake the device from deep sleep. See the 'esp32' library.
*/

/**
Touch sensor.
*/
class Touch:

  pin/Pin
  resource_ := ?

  /**
  Creates a touch pad.

  For the EPS32, the pin must be one of the following: 0, 2, 4, 12-15, 27, 32, 33.
  The $threshold is the level at which the touch pad is considered "touched". A value of 0
    conceptually disables the $get function and makes the pin unavailable as wakeup source.
  */
  constructor .pin --threshold/int?=null:
    group := resource-group_
    resource_ = touch-use_ group pin.num (threshold or 0)

  /**
  Reads the raw value of the touch pad.
  */
  read --raw/bool -> int:
    if not raw: throw "INVALID_ARGUMENT"
    if is-closed: throw "CLOSED"
    return touch-read_ resource_

  /**
  Compares the $read raw value against the threshold and returns whether the touch pad is touched.
  */
  get -> bool:
    if is-closed: throw "CLOSED"
    return (read --raw) < threshold

  /**
  The threshold at which a pin is considered "touched".

  This value is used for the $get functiond and for the deep-sleep wakeup.
  */
  threshold -> int:
    if is-closed: throw "CLOSED"
    return touch-get-threshold_ resource_

  /**
  Sets a new threshold value.

  The $new-value must be between 0 and 0xFFFF.
  */
  threshold= new-value/int:
    if is-closed: throw "CLOSED"
    if not 0 <= new-value <= 0xFFFF: throw "INVALID_ARGUMENT"
    touch-set-threshold_ resource_ new-value

  /**
  Whether this touch pad is closed.
  */
  is-closed -> bool:
    return resource_ == null

  /**
  Closes the touch pad and releases the associated resources.
  */
  close:
    resource := resource_
    if resource:
      resource_ = null
      touch-unuse_ resource-group_ resource

resource-group_ ::= touch-init_

touch-init_:
  #primitive.touch.init

touch-use_ group pin-num threshold:
  #primitive.touch.use

touch-unuse_ group resource:
  #primitive.touch.unuse

touch-read_ resource:
  #primitive.touch.read

touch-get-threshold_ resource:
  #primitive.touch.get-threshold

touch-set-threshold_ resource new-threshold:
  #primitive.touch.set-threshold
