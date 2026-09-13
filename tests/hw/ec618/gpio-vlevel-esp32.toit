// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import gpio.adc show Adc

import .wiring as wiring

/**
ESP32 half of the IO-voltage characterization.

Measures the EC618's GPIO10 output-high level on the ESP32 ADC, to confirm the
  dev-board's 3.3 V IO rail and catch a regression toward 1.8 V
  (see gpio-vlevel-ec618.toit). IO32 is
  on ADC1 (usable while Wi-Fi is up); IO14 is on ADC2 (often unavailable while
  Wi-Fi is connected — reported as an error if so). The 11 dB attenuation
  (max-voltage 3.3) reads up to ~3.1 V, so ~1.8 V vs a saturated ~3.0+ V is clearly
  distinguishable.

*/

DURATION ::= Duration --s=35

main:
  print "gpio-vlevel-esp32: measuring EC618 GPIO10 high level on IO$(wiring.ESP32-GPIO10-ADC-PINS) for $(DURATION.in-s)s"
  adcs := {:}
  wiring.ESP32-GPIO10-ADC-PINS.do: | n/int |
    error := catch: adcs[n] = Adc n --max-voltage=3.3
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
