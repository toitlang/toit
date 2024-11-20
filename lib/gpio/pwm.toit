// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .gpio

/**
Pulse-Width Modulation (PWM) support.

# Examples

A fading LED:
```
import gpio
import gpio.pwm

main:
  led := gpio.Pin 5
  // Create a PWM square wave generator with frequency 400Hz.
  generator := pwm.Pwm --frequency=400

  // Use it to drive the LED pin.
  // By default the duty factor is 0.
  channel := generator.start led

  duty-percent := 0
  step := 1
  while true:
    // Update the duty factor.
    channel.set-duty-factor duty-percent/100.0
    duty-percent += step
    if duty-percent == 0 or duty-percent == 100:
      step = -step
    sleep --ms=10
```

Driving a servo:
```
import gpio
import gpio.pwm

main:
  servo := gpio.Pin 14
  // Most servos need a 50Hz frequency. However, some models go up to
  // 400Hz. Consult the documentation for your servo.

  // Create a PWM square-wave generator with frequency 50.
  generator := pwm.Pwm --frequency=50

  // Generally, the acceptable duty-factor range of servos is 0.025 to 0.125.
  // Therefore start the pin with 0.075.
  channel := generator.start servo --duty-factor=0.075
  sleep --ms=1000

  // Max angle.
  print "max"
  channel.set-duty-factor 0.125
  sleep --ms=1500

  // Min angle.
  print "min"
  channel.set-duty-factor 0.025
  sleep --ms=1500
```
*/

/**
A Pulse-Width Modulation (PWM) instance, for managing multiple $PwmChannel.

The PWM instance controls a timer configured at the given frequency. All
  channels within the PWM instance are using the same timer. Each channel can
  in turn provide an individual duty factor.
*/
class Pwm:
  pwm_ := ?

  /**
  Constructs the PWM generator with the given $frequency and $max-frequency.

  The resolution of the PWM is dependent on the max frequency. The higher it is
    the less resolution there is.

  The frequency of the PWM must lie within a certain factor of the max frequency.
    For example, given a $max-frequency of 10KHz, the lowest frequency that is
    accepted is 20Hz.

  The $max-frequency is limited to 40MHz.
  The lowest acceptable frequency is 1Hz.

  # Advanced
  On the ESP32, the duty resolution is computed as follows:
  ```
  uint32 bits = msb(max_frequency << 1);
  uint32 resolution_bits = kMaxFrequencyBits - bits;
  duty_resolution = (ledc_timer_bit_t)resolution_bits,
  ```
  This provides the highest duty resolution for the given max frequency.

  See https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/ledc.html#supported-range-of-frequency-and-duty-resolutions
    for the limitations of the frequency with respect to the duty resolution.
  */
  constructor --frequency/int --max-frequency/int=frequency:
    pwm_ = pwm-init_ frequency max-frequency

  /**
  Starts a new $PwmChannel on the provided pin. The channel is started,
    with the given $duty-factor.

  The default $duty-factor of 0.0 means the pin stays low until otherwise configured.

  See $PwmChannel.set-duty-factor for more information on duty factors.
  */
  start pin/Pin --duty-factor/num=0.0 -> PwmChannel:
    channel := pwm-start_ pwm_ pin.num duty-factor.to-float
    return PwmChannel.from-pwm_ this channel

  /** The frequency of this PWM. */
  frequency -> int:
    return pwm-frequency_ pwm_

  /**
  Sets the frequency of the PWM.

  The $value parameter must be lower than the max frequency that was used
    during construction of this instance.

  It may not be too far below the max frequency, either.
  */
  frequency= value/int:
    pwm-set-frequency_ pwm_ value

  /**
  Closes the instance and all channels associated with it.
  */
  close:
    if not pwm_: return
    pwm-close_ pwm_
    pwm_ = null

/**
A PWM Channel for an already-opened PWM instance.

Each channel has an individual duty cycle, configured as a duty factor
  in the range of [0..1].
*/
class PwmChannel:
  pwm_/Pwm
  channel_ := ?

  constructor.from-pwm_ .pwm_ .channel_:

  /**
  Gets the current duty factor.
  */
  duty-factor -> float:
    return pwm-factor_ pwm_.pwm_ channel_

  /**
  Sets the duty factor. The duty factor is clamped to the [0..1] range.

  A duty factor of 0.0 means the pin is steady low while a duty cycle of 1.0
    means the pin is steady high. A duty factor of 0.25 means the pin will
    stay high for one quarter of the cycle, low for the remaining 3 quarters.
  */
  set-duty-factor duty-factor/num:
    pwm-set-factor_ pwm_.pwm_ channel_ duty-factor.to-float

  /**
  Closes the channel and detaches from the GPIO pin.
  */
  close:
    if not channel_: return
    pwm-close-channel_ pwm_.pwm_ channel_
    channel_ = null

pwm-init_ frequency max-frequency:
  #primitive.pwm.init

pwm-close_ pwm:
  #primitive.pwm.close

pwm-start_ pwm pin factor:
  #primitive.pwm.start

pwm-factor_ pwm channel:
  #primitive.pwm.factor

pwm-set-factor_ pwm channel factor:
  #primitive.pwm.set-factor

pwm-frequency_ pwm:
  #primitive.pwm.frequency

pwm-set-frequency_ pwm frequency:
  #primitive.pwm.set-frequency

pwm-close-channel_ pwm channel:
  #primitive.pwm.close-channel
