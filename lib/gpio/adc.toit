// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .gpio

/**
Analog-to-Digital Conversion.

This library provides ways to read analogue voltage values from GPIO pins that
  support it.

On most ESP32 variants, there are two ADCs. ADC1 should be preferred as
  ADC2 has lots of restrictions. It can't be used when WiFi is active, and some
  of the pins are strapping pins.
By default, ADC2 is disabled, and users need to pass in a flag to allow its use.

# Examples
```
import gpio
import gpio.adc show Adc

main:
  pin := gpio.Pin 34
  adc := Adc pin
  print adc.get
  adc.close
  pin.close
```

# Pins

## ESP32
ADC1: Pins 32-39
ADC2: Pins 0, 2, 4, 12-15, 25-27

## ESP32C3
ADC1: Pins 0-4
Pin 5 is an ADC pin of channel 2. However, the controller of ADC channel 2
  may enter an inoperative state and was therefore disabled by Espressif.
  An errata was published.

## ESP32C6
ADC1: Pins 0-6
No ADC2.

## ESP32S2
ADC1: Pins 1-10
ADC2: Pins 11-20

## ESP32S3
ADC1: Pins 1-10
ADC2: Pins 11-20
*/

/**
ADC unit for reading the voltage on GPIO Pins.
*/
class Adc:
  static MAX-SAMPLES-PER-CALL_ ::= 64

  pin/Pin
  resource_ := ?

  /**
  Initializes an Adc unit for the $pin.

  Use $max-voltage to indicate max voltage expected to measure. This helps to
    tune the attenuation of the underlying ADC unit. If no $max-voltage is
    provided, the ADC uses the maximum voltage range of the pin.

  # ESP32 and variants.
  On most ESP32 variants, there are two ADCs. Typically, ADC1 should be
    preferred as ADC2 has lots of restrictions. It can't be
    used when WiFi is active, and some of the pins are strapping pins.
  By default, ADC2 is disabled, and users need to pass in the
    $allow-restricted flag to allow its use.
  */
  constructor .pin --max-voltage/float?=null --allow-restricted/bool=false:
    resource_ = adc-init_ resource-freeing-module_ pin.num allow-restricted (max-voltage ? max-voltage : 0.0)

  /**
  Measures the voltage on the pin.
  */
  get --samples=64 -> float:
    if samples < 1: throw "OUT_OF_BOUNDS"
    if samples <= MAX-SAMPLES-PER-CALL_: return adc-get_ resource_ samples
    // Sample in chunks of 64, so we don't spend too much time in
    // the primitive.
    full-chunk-factor := MAX-SAMPLES-PER-CALL_.to-float / samples
    result := 0.0
    sampled := 0
    while sampled < samples:
      is-full-chunk := sampled + MAX-SAMPLES-PER-CALL_ <= samples
      chunk-size := is-full-chunk ? MAX-SAMPLES-PER-CALL_ : samples - sampled
      value := adc-get_ resource_ chunk-size
      result += value * (is-full-chunk ? full-chunk-factor : (chunk-size.to-float / samples))
      sampled += chunk-size
    return result

  /**
  Measures the voltage on the pin and returns the obtained raw value.

  On the ESP32 the ADC readings are 12 bits, so the value will be in the
    range 0-4095.

  The returned value is not scaled to the voltage range of the pin.
  The value is not using the calibration data of the chip.
  */
  get --raw/bool -> int:
    if not raw: throw "INVALID_ARGUMENT"
    return adc-get-raw_ resource_

  /**
  Closes the ADC unit and releases the associated resources.
  */
  close:
    if resource_:
      adc-close_ resource_
      resource_ = null

adc-init_ group num allow-restricted max:
  #primitive.adc.init

adc-get_ resource samples:
  #primitive.adc.get

adc-get-raw_ resource:
  #primitive.adc.get-raw

adc-close_ resource:
  #primitive.adc.close
