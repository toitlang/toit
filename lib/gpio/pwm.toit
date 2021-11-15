// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .pin

/**
Pulse-Width Modulation (PWM) support.
*/

/**
A Pulse-Width Modulation (PWM) instance, for managing multiple $PwmChannel.

The PWM instance controls a timer configured at the given frequency. All
  channels within the PWM instance are using the same timer. Each channel can
  in turn provide an individual duty factor.
*/
class Pwm:
  pwm_ := ?

  constructor --frequency/int:
    pwm_ = pwm_init_ frequency

  /**
  Starts a new $PwmChannel on the provided pin. The channel is started,
    with the given $duty_factor.

  The default $duty_factor of 0.0 means the pin stays low until otherwise configured.

  See $PwmChannel.set_duty_factor for more information on duty factors.
  */
  start pin/Pin --duty_factor/num=0.0 -> PwmChannel:
    channel := pwm_start_ pwm_ pin.num duty_factor.to_float
    return PwmChannel.from_pwm_ this channel

  /**
  Closes the instance and all channels associated with it.
  */
  close:
    if not pwm_: return
    pwm_close_ pwm_
    pwm_ = null

/**
A PWM Channel for an already-opened PWM instance.

Each channel has an individual duty cycle, configured as a duty factor
  in the range of [0..1].
*/
class PwmChannel:
  pwm_/Pwm
  channel_ := ?

  constructor.from_pwm_ .pwm_ .channel_:

  /**
  Gets the current duty factor.
  */
  duty_factor -> float:
    return pwm_factor_ pwm_.pwm_ channel_

  /**
  Sets the duty factor. The duty factor is clamped to the [0..1] range.

  A duty factor of 0.0 means the pin is steady low while a duty cycle of 1.0
    means the pin is steady high. A duty factor of 0.25 means the pin will
    stay high for one quarter of the cycle, low for the remaining 3 quarters.
  */
  set_duty_factor duty_factor/num:
    pwm_set_factor_ pwm_.pwm_ channel_ duty_factor.to_float

  /**
  Closes the channel and detaches from the GPIO pin.
  */
  close:
    if not channel_: return
    pwm_close_channel_ pwm_.pwm_ channel_
    channel_ = null

pwm_init_ frequency:
  #primitive.pwm.init

pwm_close_ pwm:
  #primitive.pwm.close

pwm_start_ pwm pin factor:
  #primitive.pwm.start

pwm_factor_ pwm channel:
  #primitive.pwm.factor

pwm_set_factor_ pwm channel factor:
  #primitive.pwm.set_factor

pwm_close_channel_ pwm channel:
  #primitive.pwm.close_channel
