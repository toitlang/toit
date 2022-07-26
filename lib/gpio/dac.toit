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
  static COSINE_WAVE_SCALE_1/int ::= 0
  /** Scale factor for the cosine wave generator that yields half amplitude. */
  static COSINE_WAVE_SCALE_2/int ::= 1
  /** Scale factor for the cosine wave generator that yields 1/4 amplitude. */
  static COSINE_WAVE_SCALE_4/int ::= 2
  /** Scale factor for the cosine wave generator that yields 1/8 amplitude. */
  static COSINE_WAVE_SCALE_8/int ::= 3

  /** Phase shift constant of the cosine wave generator: 0° */
  static COSINE_WAVE_PHASE_0/int ::= 2
  /** Phase shift constant of the cosine wave generator: 180° */
  static COSINE_WAVE_PHASE_180/int ::= 3

  pin/Pin
  resource_ := ?

  /**
  Initializes a Dac channel.

  If provided, sets the output of the dac to the given $initial_voltage. Otherwise, the
    pin is set to emit 0V.
  */
  constructor .pin --initial_voltage/float?=null:
    group := resource_group_
    initial_value := initial_voltage ? (voltage_to_dac_value_ initial_voltage) : 0
    resource_ = dac_use_ group pin.num 0

  /**
  Sets the output voltage of the DAC channel to $voltage.
  */
  set voltage/float -> none:
    if is_closed: throw "CLOSED"
    dac_set_ resource_ (voltage_to_dac_value_ voltage)

  /**
  Whether this DAC channel is closed.
  */
  is_closed -> bool:
    return resource_ == null

  /**
  Closes the DAC channel releases the associated resources.
  */
  close:
    resource := resource_
    if resource:
      resource_ = null
      dac_unuse_ resource_group_ resource

  /**
  Starts a cosine wave generator on the DAC channel.

  The $frequency must be in range [130 .. 5500].
  The $scale must be one of $COSINE_WAVE_SCALE_1, $COSINE_WAVE_SCALE_2, $COSINE_WAVE_SCALE_4, or $COSINE_WAVE_SCALE_8.
  The $phase must be either $COSINE_WAVE_PHASE_0 or $COSINE_WAVE_PHASE_180.

  By default, the wave is centered at VCC/2, independent of the $scale. By providing an $offset, the wave can be
    shifted vertically. The $offset must be in range [-1.0 .. 1.0], where -1.0 means that the wave is centered at 0V
    (cutting off anything that tips below), and 1.0 means that the wave is centered at VCC (cutting off anything that
    tips above).
  */
  cosine_wave --frequency/int
      --scale/int=COSINE_WAVE_SCALE_1
      --phase/int=COSINE_WAVE_PHASE_0
      --offset/float=0.0:
    if not COSINE_WAVE_SCALE_1 <= scale <= COSINE_WAVE_SCALE_8: throw "INVALID_ARGUMENT"
    if phase != COSINE_WAVE_PHASE_0 and phase != COSINE_WAVE_PHASE_180: throw "INVALID_ARGUMENT"
    if not -1.0 <= offset <= 1.0: throw "INVALID_ARGUMENT"
    int_offset := (offset < 0.0 ? 128 * offset : 127 * offset).to_int
    dac_cosine_wave resource_ scale phase frequency int_offset

  static voltage_to_dac_value_ voltage/float:
    if not 0.0 <= voltage <= 3.3: throw "INVALID_ARGUMENT"
    return (voltage * (0xFF / 3.3)).to_int

resource_group_ ::= dac_init_

dac_init_:
  #primitive.dac.init

dac_use_ group pin_num initial_value:
  #primitive.dac.use

dac_unuse_ group resource:
  #primitive.dac.unuse

dac_set_ resource value:
  #primitive.dac.set

dac_cosine_wave resource scale phase frequency offset:
  #primitive.dac.cosine_wave
