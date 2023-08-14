// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the ADC.

Note that this test accesses ADC2 which is restricted and can't be used
  while WiFi is running.

On Jaguar use:
  `jag container install -D jag.disabled -D jag.timeout=1m adc adc.toit`


Setup:
Connect pin 12 to pin 14 with a 330 Ohm resistor.
Connect pin 14 to pin 32 with a 330 Ohm resistor.
Connect pin 32 to pin 25 with a 330 Ohm resistor.
*/

import gpio.adc as gpio
import gpio
import expect show *

ADC1-PIN ::= 32
ADC2-PIN ::= 14
CONTROL-PIN ::= 25
V33-PIN ::= 12

main:
  test-restricted := true

  v33-pin := gpio.Pin V33-PIN --output
  v33-pin.set 1

  adc1-pin := gpio.Pin ADC1-PIN
  control-pin := gpio.Pin CONTROL-PIN --output

  adc := gpio.Adc adc1-pin
  control-pin.set 0
  // The resistors create a voltage divider of ration 2/3.
  value := adc.get
  expect 1.0 < value < 1.2

  raw-value := adc.get --raw
  expect 1115 < raw-value < 1500

  control-pin.set 1
  // The voltage is now 3.3V.
  value = adc.get
  expect value > 3.0
  raw-value = adc.get --raw
  expect-equals 4095 raw-value

  // Test that we correctly measure when the sample size is big.
  control-pin.set 0
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

  if not test-restricted: return
  print "Testing restricted ADC"
  print "This only works if no WiFi is running"
  print "There are other restrictings."

  adc2-pin := gpio.Pin ADC2-PIN

  expect-throw "OUT_OF_RANGE":
    adc = gpio.Adc adc2-pin

  adc = gpio.Adc --allow-restricted adc2-pin
  control-pin.set 0
  // The resistors create a voltage divider of ration 2/3.
  value = adc.get
  expect 1.8 < value < 2.6

  control-pin.set 1
  // Now the voltage should be 3.3V.
  value = adc.get
  expect value > 3.0

  print "done"
