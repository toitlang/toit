// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the DAC functionality of the ESP32.

Setup:
Connect pin 25 to pin 32.
Connect pin 26 to pin 33.
*/

import gpio
import gpio.dac as gpio
import gpio.adc as gpio
import expect show *

ADC_IN1 := 32
ADC_IN2 := 33
DAC_OUT1 := 25
DAC_OUT2 := 26

test_wave data/List:
  bucket1 := 0
  bucket2 := 0
  bucket3 := 0
  bucket4 := 0
  data.do:
    if it < 0.495: bucket1++
    else if it < 1.65: bucket2++
    else if it < 2.8: bucket3++
    else: bucket4++
  expect bucket1 >= data.size / 8
  expect bucket2 >= data.size / 8
  expect bucket3 >= data.size / 8
  expect bucket4 >= data.size / 8

  sum := data.reduce: | a b | a + b
  average := sum / data.size
  expect 1.3 <= average <= 2.0

main:
  dac1 := gpio.Dac (gpio.Pin DAC_OUT1)
  dac2 := gpio.Dac (gpio.Pin DAC_OUT2)
  adc1 := gpio.Adc (gpio.Pin ADC_IN1)
  adc2 := gpio.Adc (gpio.Pin ADC_IN2)

  dac1.set 1.0
  dac2.set 2.0

  expect 0.9 <= adc1.get <= 1.1
  expect 1.9 <= adc2.get <= 2.1

  dac1.cosine_wave --frequency=130
  dac2.cosine_wave --frequency=130 --phase=gpio.Dac.COSINE_WAVE_PHASE_180

  data1 := List 1000
  data2 := List 1000
  data1.size.repeat:
    data1[it] = (adc1.get --samples=1)
    data2[it] = (adc2.get --samples=1)

  in_range := 0
  // The waves are offset by 180 degrees, centered on 1.65V.
  100.repeat:
    diff1 := (data1[it] - 1.65).abs
    diff2 := (data2[it] - 1.65).abs
    if (diff1 - diff2).abs < 0.4: in_range++
  expect in_range >= 80

  // Expect to see the majority of values.
  test_wave data1
  test_wave data2

  dac1.set 0.5
  expect 0.4 <= adc1.get <= 0.6

  // The dac2 should still be a wave.
  data2.size.repeat:
    data2[it] = adc2.get --samples=1
  test_wave data2

  dac2.set 0.8
  expect 0.7 <= adc2.get <= 0.9

  dac1.cosine_wave --frequency=130
  data1.size.repeat:
    data1[it] = adc1.get --samples=1
  test_wave data1

  dac1.set 0.0
  dac2.set 0.0

  expect 0.0 <= adc1.get <= 0.2  // Remember that the ADC doesn't do well on low values.
  expect 0.0 <= adc2.get <= 0.2

  dac1.cosine_wave --frequency=130 --offset=-1.0
  data1.size.repeat:
    data1[it] = adc1.get --samples=1
  // 50% of the wave should be cut off now.
  cut_off := 0
  data1.do:
    if it < 0.2: cut_off++
  expect cut_off >= data1.size / 3

  dac1.cosine_wave --frequency=130 --offset=1.0
  data1.size.repeat:
    data1[it] = adc1.get --samples=1
  // 50% of the wave should be cut off now.
  cut_off = 0
  data1.do:
    if it > 3.1: cut_off++
  expect cut_off >= data1.size / 3

  dac1.close
  dac2.close

  print "done"
