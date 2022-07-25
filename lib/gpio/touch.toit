// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .gpio

/**
Touch Sensor support.

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
Touch Sensor.
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
    group := resource_group_
    resource_ = touch_use_ group pin.num (threshold or 0)

  /**
  Reads the raw value of the touch pad.
  */
  read --raw/bool -> int:
    if not raw: throw "INVALID_ARGUMENT"
    if is_closed: throw "CLOSED"
    return touch_read_ resource_

  /**
  Compares the $read raw value against the threshold and returns whether the touch pad is touched.
  */
  get -> bool:
    if is_closed: throw "CLOSED"
    return (read --raw) < threshold

  /**
  The threshold at which a pin is considered "touched".

  This value is used for the $get functiond and for the deep-sleep wakeup.
  */
  threshold -> int:
    if is_closed: throw "CLOSED"
    return touch_get_threshold_ resource_

  /**
  Sets a new threshold value.

  The $new_value must be between 0 and 0xFFFF.
  */
  threshold= new_value/int:
    if is_closed: throw "CLOSED"
    if not 0 <= new_value <= 0xFFFF: throw "INVALID_ARGUMENT"
    touch_set_threshold_ resource_ new_value

  /**
  Whether this touch pad is closed.
  */
  is_closed -> bool:
    return resource_ == null

  /**
  Closes the touch pad and releases the associated resources.
  */
  close:
    resource := resource_
    if resource:
      resource_ = null
      touch_unuse_ resource_group_ resource

resource_group_ ::= touch_init_

touch_init_:
  #primitive.touch.init

touch_use_ group pin_num threshold:
  #primitive.touch.use

touch_unuse_ group resource:
  #primitive.touch.unuse

touch_read_ resource:
  #primitive.touch.read

touch_get_threshold_ resource:
  #primitive.touch.get_threshold

touch_set_threshold_ resource new_threshold:
  #primitive.touch.set_threshold
