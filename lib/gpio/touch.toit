// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system

import .gpio

/**
Touch sensor support.

This library provides ways to use some GPIO pins as capacitive touch pads.

# Raw readings and detection polarity
The value returned by $Touch.read is a count derived from the charge and
  discharge cycles of the touch pad. A finger on the pad increases the pad's
  capacitance, but the direction in which that changes the raw reading depends
  on the chip family:

- On the original ESP32 the sensor counts charge/discharge cycles within a
  fixed time window. Extra capacitance slows those cycles, so the raw reading
  *decreases* on touch. The hardware threshold is an absolute cutoff, and the
  pad is considered touched when the raw reading falls *below* the threshold.
- On the ESP32-S2 and ESP32-S3 the sensor instead counts clock ticks for a
  fixed number of charge/discharge cycles. Extra capacitance makes each cycle
  longer, so the raw reading *increases* on touch. The hardware threshold is
  a delta added to an auto-calibrated benchmark (which tracks the untouched
  reading), and the pad is considered touched when the raw reading exceeds
  benchmark + threshold.

Note that the raw ranges also differ widely between chips: an untouched ESP32
  pad typically reads in the low hundreds, while an untouched ESP32-S3 pad
  reads in the tens of thousands and rises to several hundred thousand on
  touch. A threshold calibrated on one chip is not meaningful on another.

# Calibration
Call $Touch.calibrate on a freshly constructed, untouched pad. It samples the
  raw reading, picks a threshold that triggers on a roughly one-third change,
  and stores the observed baseline so that $Touch.get can report presses
  correctly on both polarities.

For applications that need a custom calibration strategy, $Touch.threshold and
  $Touch.baseline= can be set directly. Keep in mind the per-chip meaning of
  the threshold described above.

# ESP32
Pins 0, 2, 4, 12-15, 27, 32, 33 can be used as touch pads.

# ESP32-C3
The ESP32-C3 does not have touch support.

# ESP32-C6
The ESP32-C6 does not have touch support.

# ESP32-S2
Pins 1-14 can be used as touch pads.

# ESP32-S3
Pins 1-14 can be used as touch pads.

# Examples
```
import gpio
import gpio.touch show Touch

main:
  // Pin 32 is a touch pad on the original ESP32. See the per-chip sections
  // above for which pins are available on other chips.
  touch := Touch (gpio.Pin 32)
  touch.calibrate
  while not touch.get: sleep --ms=10
  print "touched"
  touch.close
```

A touch pad can be used to wake the device from deep sleep. See the 'esp32' library.
*/

RAW-RISES-ON-TOUCH_/bool ::= (system.architecture == system.ARCHITECTURE-ESP32S2) or (system.architecture == system.ARCHITECTURE-ESP32S3)

/**
Touch sensor.
*/
class Touch:

  pin/Pin
  resource_ := ?
  baseline_/int? := null

  /**
  Creates a touch pad.

  The $pin must refer to a touch-capable GPIO on the current chip. See the
    class-level documentation for the set of supported pins.

  The $threshold is used by $get and for deep-sleep wakeup. A value of 0
    disables $get and makes the pin unavailable as a wakeup source. If left
    null, call $calibrate to pick one automatically.
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
  Calibrates the touch pad.

  Reads the raw value $iterations times while the pad must be untouched,
    records the average as the $baseline, and sets $threshold to trigger on
    a roughly one-third change from that baseline. The threshold sign and
    meaning is handled per chip; see the library-level documentation.

  Returns the computed baseline.
  */
  calibrate --iterations/int=16 -> int:
    if is-closed: throw "CLOSED"
    if iterations <= 0: throw "INVALID_ARGUMENT"
    sum := 0
    iterations.repeat: sum += read --raw
    new-baseline := sum / iterations
    delta := new-baseline / 3
    baseline = new-baseline
    threshold = RAW-RISES-ON-TOUCH_ ? delta : new-baseline - delta
    return new-baseline

  /**
  Returns whether the touch pad is currently pressed according to the
    configured $threshold.

  On the ESP32 this is true while the raw reading is below the threshold. On
    the ESP32-S2/S3 it is true while the raw reading exceeds $baseline by at
    least the threshold; $calibrate (or $baseline=) must have been called
    first. A $threshold of 0 always returns false.
  */
  get -> bool:
    if is-closed: throw "CLOSED"
    current-threshold := threshold
    if current-threshold == 0: return false
    raw := read --raw
    if RAW-RISES-ON-TOUCH_:
      if baseline_ == null: throw "NOT_CALIBRATED"
      return raw > baseline_ + current-threshold
    return raw < current-threshold

  /**
  The idle baseline recorded by $calibrate, or null if the pad has not been
    calibrated and no baseline has been set via $baseline=.

  Only used on the ESP32-S2/S3, where $get compares the raw reading against
    `baseline + threshold`.
  */
  baseline -> int?:
    return baseline_

  /**
  Sets the idle baseline used by $get on the ESP32-S2/S3.

  Prefer $calibrate unless you have a specific reason to override it.
  */
  baseline= value/int?:
    baseline_ = value

  /**
  The threshold at which a pin is considered "touched".

  This value is used for $get and for the deep-sleep wakeup.
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
