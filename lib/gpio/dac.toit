// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .gpio

/**
Digital-to-Analog Conversion.

This library provides ways to output analog voltages on the GPIO pins that support it.

On the ESP32, pins 25 and 26 have an ADC converter.

# Examples
```
import gpio
import gpio.dac show Dac

main:
  dac := Dac (gpio.Pin 25)
  dac.set 2.3
  sleep --ms=1_000
  dac.close
```
*/

/**
Digital-to-Analog channel for generating a voltage on a GPIO pin.
*/
class Dac:
  /** Scale factor for the cosine wave generator that yields full amplitude. */
  static COSINE-WAVE-SCALE-1/int ::= 1
  /** Scale factor for the cosine wave generator that yields half amplitude. */
  static COSINE-WAVE-SCALE-2/int ::= 2
  /** Scale factor for the cosine wave generator that yields 1/4 amplitude. */
  static COSINE-WAVE-SCALE-4/int ::= 4
  /** Scale factor for the cosine wave generator that yields 1/8 amplitude. */
  static COSINE-WAVE-SCALE-8/int ::= 8

  /** Phase shift constant of the cosine wave generator: 0° */
  static COSINE-WAVE-PHASE-0/int ::= 0
  /** Phase shift constant of the cosine wave generator: 180° */
  static COSINE-WAVE-PHASE-180/int ::= 180

  pin/Pin
  resource_ := ?

  /**
  Initializes a DAC channel.

  If provided, sets the output of the dac to the given $initial-voltage. Otherwise, the
    pin is set to emit 0V.
  */
  constructor .pin --initial-voltage/float=0.0:
    group := resource-group_
    resource_ = dac-use_ group pin.num
    set initial-voltage


  /**
  Sets the output voltage of the DAC channel to $voltage.
  */
  set voltage/float -> none:
    if is-closed: throw "CLOSED"
    dac-set_ resource_ (voltage-to-dac-value_ voltage)

  /**
  Whether this DAC channel is closed.
  */
  is-closed -> bool:
    return resource_ == null

  /**
  Closes the DAC channel releases the associated resources.
  */
  close:
    resource := resource_
    if resource:
      resource_ = null
      dac-unuse_ resource-group_ resource

  /**
  Starts a cosine wave generator on the DAC channel.

  The $frequency must be in range [130 .. 5500].
  The $scale must be one of $COSINE-WAVE-SCALE-1, $COSINE-WAVE-SCALE-2, $COSINE-WAVE-SCALE-4, or $COSINE-WAVE-SCALE-8.
  The $phase must be either $COSINE-WAVE-PHASE-0 or $COSINE-WAVE-PHASE-180.

  By default, the wave is centered at VCC/2, independent of the $scale. By providing an $offset, the wave can be
    shifted vertically. The $offset must be in range [-1.0 .. 1.0], where -1.0 means that the wave is centered at 0V
    (cutting off anything that tips below), and 1.0 means that the wave is centered at VCC (cutting off anything that
    tips above).

  The ESP32 has only one wave generator. Behavior is undefined if multiple DAC channels use it at the same time.
  */
  cosine-wave --frequency/int
      --scale/int=COSINE-WAVE-SCALE-1
      --phase/int=COSINE-WAVE-PHASE-0
      --offset/float=0.0:
    if not 130 <= frequency <= 5500: throw "INVALID_ARGUMENT"
    if not COSINE-WAVE-SCALE-1 <= scale <= COSINE-WAVE-SCALE-8: throw "INVALID_ARGUMENT"
    if phase != COSINE-WAVE-PHASE-0 and phase != COSINE-WAVE-PHASE-180: throw "INVALID_ARGUMENT"
    if not -1.0 <= offset <= 1.0: throw "INVALID_ARGUMENT"
    int-offset := (offset < 0.0 ? 128 * offset : 127 * offset).to-int
    dac-cosine-wave resource_ scale phase frequency int-offset

  static voltage-to-dac-value_ voltage/float:
    if not 0.0 <= voltage <= 3.3: throw "INVALID_ARGUMENT"
    return (voltage * (0xFF / 3.3)).to-int

resource-group_ ::= dac-init_

dac-init_:
  #primitive.dac.init

dac-use_ group pin-num:
  #primitive.dac.use

dac-unuse_ group resource:
  #primitive.dac.unuse

dac-set_ resource value:
  #primitive.dac.set

dac-cosine-wave resource scale phase frequency offset:
  #primitive.dac.cosine-wave
