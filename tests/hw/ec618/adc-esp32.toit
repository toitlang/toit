// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the ADC HW test: drives the EC618 ADC inputs.

Outputs a slow square wave on both DACs, alternating low/high, so the EC618
half (adc-ec618.toit) sees its ADC readings track the DAC. The DAC outputs go
through voltage dividers (the EC618 ADC tops out around 1.8 V, the ESP32 DAC
swings 0-3.3 V).

Wiring: ESP32 IO25 (DAC1) -> divider -> EC618 ADC0 (pin 3)
        ESP32 IO26 (DAC2) -> divider -> EC618 ADC1 (pin 4)

Run via Jaguar: jag run tests/hw/ec618/adc-esp32.toit --device <esp32>
*/

import gpio
import gpio.dac show Dac

DAC1 ::= 25
DAC2 ::= 26
LOW ::= 0.0
HIGH ::= 3.0
HALF-PERIOD ::= Duration --s=2
DURATION ::= Duration --s=60

main:
  dac1 := Dac (gpio.Pin DAC1)
  dac2 := Dac (gpio.Pin DAC2)
  print "adc-esp32: square wave $(LOW)V/$(HIGH)V on IO$DAC1 + IO$DAC2 for $(DURATION.in-s)s"
  deadline := Time.monotonic-us + DURATION.in-us
  high := false
  while Time.monotonic-us < deadline:
    high = not high
    v := high ? HIGH : LOW
    dac1.set v
    dac2.set v
    sleep HALF-PERIOD
  dac1.set 0.0
  dac2.set 0.0
  dac1.close
  dac2.close
  print "adc-esp32: done"
