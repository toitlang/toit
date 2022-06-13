/*  */// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the ADC.

Note that this test accesses ADC2 which is restricted and can't be used
  while WiFi is running.

Setup:
Connect 3V3 to pin 12 with a 330 Ohm resistor.
Connect pin 12 to pin 32 with a 330 Ohm resistor.
Connect pin 32 to pin 25 with a 330 Ohm resistor.
*/

import gpio.adc as gpio
import gpio
import expect show *

ADC1_PIN ::= 32
ADC2_PIN ::= 12
CONTROL_PIN ::= 25

main:
  test_restricted := true

  adc1_pin := gpio.Pin ADC1_PIN
  control_pin := gpio.Pin CONTROL_PIN --output

  adc := gpio.Adc adc1_pin
  control_pin.set 0
  // The resistors create a voltage divider of ration 2/3.
  value := adc.get
  print value
  expect 0.9 < value < 1.3

  control_pin.set 1
  // The voltage is now 3.3V.
  value = adc.get
  expect value > 3.0

  // Test that we correctly measure when the sample size is big.
  control_pin.set 0
  values := [
    adc.get --samples=5,
    adc.get --samples=64,
    adc.get --samples=127,
    adc.get --samples=128,
    adc.get --samples=255,
    adc.get --samples=256,
    adc.get --samples=1023,
    adc.get --samples=1024,
  ]
  average := values.reduce: | a b | a + b
  average /= values.size
  diffs := values.map: | v | (v - average).abs
  expect (diffs.every: it < 0.1)

  if not test_restricted: return
  print "Testing restricted ADC"
  print "This only works if no WiFi is running"
  print "There are other restrictings."

  adc2_pin := gpio.Pin ADC2_PIN

  expect_throw "OUT_OF_RANGE":
    adc = gpio.Adc adc2_pin

  adc = gpio.Adc --allow_restricted adc2_pin
  control_pin.set 0
  // The resistors create a voltage divider of ration 2/3.
  value = adc.get
  expect 1.8 < value < 2.6

  control_pin.set 1
  // Now the voltage should be 3.3V.
  value = adc.get
  expect value > 3.0

  print "done"
