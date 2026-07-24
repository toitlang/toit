// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import gpio.adc show Adc

/**
ESP32 half of the IO-voltage characterization.

Measures the EC618's GPIO10 output-high level on the ESP32 ADC, to tell whether
  the dev-board IO rail is ~1.8 V or ~3.3 V (see gpio-vlevel-ec618.toit). IO32 is
  on ADC1 (usable while Wi-Fi is up); IO14 is on ADC2 (often unavailable while
  Wi-Fi is connected — reported as an error if so). The 11 dB attenuation
  (max-voltage 3.3) reads up to ~3.1 V, so ~1.8 V vs a saturated ~3.0+ V is clearly
  distinguishable.

Wiring: EC618 GPIO10 / PAD25 <-> ESP32 IO32 (ADC1) and IO14 (ADC2).

Run via Jaguar (output to the serial console), BEFORE the EC618 half:

```
  jag run tests/hw/ec618/gpio-vlevel-esp32.toit --device <esp32>
```
*/

PINS ::= [32, 14]              // 32 = ADC1 (Wi-Fi-safe); 14 = ADC2 (may error under Wi-Fi).
DURATION ::= Duration --s=35

main:
  print "gpio-vlevel-esp32: measuring EC618 GPIO10 high level on IO$PINS for $(DURATION.in-s)s"
  adcs := {:}
  PINS.do: | n/int |
    error := catch: adcs[n] = Adc (gpio.Pin n) --max-voltage=3.3
    if error: print "gpio-vlevel-esp32: IO$n ADC init error: $error"
  end := Time.monotonic-us + DURATION.in-us
  while Time.monotonic-us < end:
    adcs.do: | n/int adc/Adc |
      error := catch:
        print "gpio-vlevel-esp32: IO$n = $(%.3f (adc.get --samples=64)) V"
      if error: print "gpio-vlevel-esp32: IO$n read error: $error"
    sleep --ms=2000
  adcs.do: | n/int adc/Adc | adc.close
  print "gpio-vlevel-esp32: done"
