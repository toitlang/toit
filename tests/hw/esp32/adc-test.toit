// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the ADC.

Note that this test accesses ADC2 which is restricted and can't be used
  while WiFi is running.

On Jaguar use:
  `jag container install -D jag.disabled -D jag.timeout=1m adc adc.toit`


For the setup, see the documentation at $Variant.adc1-pin.
*/

import gpio.adc as gpio
import gpio
import system
import expect show *

import .test
import .variants

main:
  run-test: test

test:
  test-restricted := true

  v33-pin := gpio.Pin Variant.CURRENT.adc-v33-pin --output
  v33-pin.set 1
  print "pin v33 set"
  sleep --ms=2000
  print "off"
  v33-pin.set 0
  sleep --ms=2000
  print "on"
  v33-pin.set 1

  adc1-pin := gpio.Pin Variant.CURRENT.adc1-pin
  control-pin := gpio.Pin Variant.CURRENT.adc-control-pin --output

  adc := gpio.Adc adc1-pin
  control-pin.set 0
  print "control pin set to 0"
  sleep --ms=1000
  print "1"
  control-pin.set 1
  sleep --ms=1000
  print "off"
  control-pin.set 0

  // The resistors create a voltage divider of ration 2/3.
  value := adc.get
  print (adc.get --raw)
  sleep --ms=5000
  print "ADC value: $value"
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

  adc2-pin := gpio.Pin Variant.CURRENT.adc2-pin

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
