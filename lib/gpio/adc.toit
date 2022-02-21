// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .gpio

/**
Analog-to-Digital Conversion.

This library provides ways to read analogue voltage values from GPIO pins that
  support it.

On the ESP32, only the ADC1 (pins 32-39) is supported. The ADC2 has too many
  restrictions (cannot be used when WiFi is active, and some of the pins are
  strapping pins), and is therefore disabled.

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
  pin/Pin
  state_ := ?

  /**
  Initializes an Adc unit for the $pin.

  Use $max to indicate max voltage expected to measure. This helps to
    tune the attenuation of the underlying ADC unit.

  Note that chip-specific limitations apply, generally the precision at
    various voltage ranges.

  On the ESP32, only the ADC1 (pins 32-39) is supported. The ADC2 has too many
    restrictions (cannot be used when WiFi is active, and some of the pins are
    strapping pins), and is therefore disabled.
  */
  constructor .pin --max_voltage/float?=null:
    state_ = adc_init_ resource_freeing_module_ pin.num (max_voltage ? max_voltage : 0.0)

  /**
  Measures the voltage on the Pin.
  */
  get --samples=64 -> float:
    return adc_get_ state_ samples

  /**
  Closes the ADC unit and releases the associated resources.
  */
  close:
    if state_:
      adc_close_ state_
      state_ = null

adc_init_ group num max:
  #primitive.adc.init

adc_get_ state samples:
  #primitive.adc.get

adc_close_ state:
  #primitive.adc.close
