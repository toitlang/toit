// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Analog-to-Digital Conversion on the EC618.

Unlike the ESP32 (where the ADC sits on a GPIO pad), the EC618's application
ADC inputs are dedicated analog channels addressed by channel number:
- channel 0 -> AIO3 (the board's "ADC0" pin)
- channel 1 -> AIO4 (the board's "ADC1" pin)

The converter core measures 0..1.2 V; wider ranges (up to 3.8 V) engage an
internal resistor divider, selected from the $Adc.constructor's $max-voltage.

# Example
```
import ec618.adc show Adc

main:
  adc := Adc 0 --max-voltage=1.9
  print "$(adc.get)V"
  adc.close
```
*/

/**
An ADC channel on the EC618.
*/
class Adc:
  static MAX-SAMPLES-PER-CALL_ ::= 64

  channel/int
  resource_ := ?

  /**
  Initializes an $Adc on the given $channel (0 -> AIO3, 1 -> AIO4).

  Use $max-voltage to indicate the largest voltage you expect to measure; the
    smallest internal range that covers it is selected, for the best
    resolution. The supported range maxima are 1.2, 1.4, 1.6, 1.9, 2.4, 2.7,
    3.2 and 3.8 V. If $max-voltage is null the widest (3.8 V) range is used.
  */
  constructor .channel --max-voltage/float?=null:
    resource_ = adc-init_ resource-freeing-module_ channel false (max-voltage ? max-voltage : 0.0)

  /**
  Measures the voltage on the channel, averaged over $samples conversions.
  */
  get --samples/int=64 -> float:
    if samples < 1: throw "OUT_OF_BOUNDS"
    if samples <= MAX-SAMPLES-PER-CALL_: return adc-get_ resource_ samples
    // Sample in chunks of 64 so we don't spend too long in the primitive.
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
  Measures the channel and returns the raw 12-bit conversion code (0..4095).

  The value is not scaled to a voltage and does not account for the range
    divider.
  */
  get --raw/bool -> int:
    if not raw: throw "INVALID_ARGUMENT"
    return adc-get-raw_ resource_

  /**
  Closes the ADC channel and releases the associated resources.
  */
  close:
    if resource_:
      adc-close_ resource_
      resource_ = null

adc-init_ group channel allow-restricted max:
  #primitive.adc.init

adc-get_ resource samples:
  #primitive.adc.get

adc-get-raw_ resource:
  #primitive.adc.get-raw

adc-close_ resource:
  #primitive.adc.close
