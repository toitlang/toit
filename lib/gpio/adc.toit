// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .gpio

/**
Analog-to-Digital Conversion.

This library provides ways to read analogue voltage values from GPIO pins that
  support it.

On the ESP32, there are two ADCs. ADC1 (pins 32-39) should be preferred as
  ADC2 (pins 0, 2, 4, 12-15, 25-27) has lots of restrictions. It can't be
  used when WiFi is active, and some of the pins are
  strapping pins). By default, ADC2 is disabled, and users need to pass in a flag to
  allow its use.

# Examples
```
import gpio
import gpio.adc show Adc

main:
  adc := Adc (gpio.Pin 34)
  print adc.get
  adc.close
```
*/

/**
ADC unit for reading the voltage on GPIO Pins.
*/
class Adc:
  static MAX_SAMPLES_PER_CALL_ ::= 64

  pin/Pin
  resource_ := ?

  /**
  Initializes an Adc unit for the $pin.

  Use $max to indicate max voltage expected to measure. This helps to
    tune the attenuation of the underlying ADC unit.

  Note that chip-specific limitations apply, generally the precision at
    various voltage ranges.

  If $allow_restricted is provided, allows pins that are restricted.
    See the ESP32 section below.

  # ESP32
  On the ESP32, there are two ADCs. ADC1 (pins 32-39) should be preferred as
    ADC2 (pins 0, 2, 4, 12-15, 25-27) has lots of restrictions. It can't be
    used when WiFi is active, and some of the pins are
    strapping pins). By default, ADC2 is disabled, and users need to pass in the
    $allow_restricted flag to allow its use.
  */
  constructor .pin --max_voltage/float?=null --allow_restricted/bool=false:
    resource_ = adc_init_ resource_freeing_module_ pin.num allow_restricted (max_voltage ? max_voltage : 0.0)

  /**
  Measures the voltage on the Pin.
  */
  get --samples=64 -> float:
    if samples < 1: throw "OUT_OF_BOUNDS"
    if samples <= MAX_SAMPLES_PER_CALL_: return adc_get_ resource_ samples
    // Sample in chunks of 64, so we don't spend too much time in
    // the primitive.
    full_chunk_factor := MAX_SAMPLES_PER_CALL_.to_float / samples
    result := 0.0
    sampled := 0
    while sampled < samples:
      is_full_chunk := sampled + MAX_SAMPLES_PER_CALL_ <= samples
      chunk_size := is_full_chunk ? MAX_SAMPLES_PER_CALL_ : samples - sampled
      value := adc_get_ resource_ chunk_size
      result += value * (is_full_chunk ? full_chunk_factor : (chunk_size.to_float / samples))
      sampled += chunk_size
    return result

  /**
  Closes the ADC unit and releases the associated resources.
  */
  close:
    if resource_:
      adc_close_ resource_
      resource_ = null

adc_init_ group num allow_restricted max:
  #primitive.adc.init

adc_get_ resource samples:
  #primitive.adc.get

adc_close_ resource:
  #primitive.adc.close
