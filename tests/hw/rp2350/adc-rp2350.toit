// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-throw
import gpio
import gpio.adc show Adc

import .wiring as wiring

/**
RP2350B half of the ADC hardware test.

The ESP32 companion drives a 0.0..3.0 V staircase on both inputs. GP40 is fed
  through 4 kohm and GP41 through 10 kohm. Sampling the channels alternately
  exercises ADC mux switching and the higher source impedance on GP41.

Each channel must cover nearly the full applied range and reproduce all five
  intermediate levels after a two-point gain/offset fit. The fit tolerates the
  ESP32 DAC and board supply errors while still checking ADC linearity. The
  endpoint bounds ensure that a clean but incorrectly scaled waveform fails.
*/

DAC-LEVELS ::= [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
SAMPLE-COUNT ::= 240
SAMPLE-INTERVAL ::= Duration --ms=125
SAMPLES-PER-READING ::= 16

MIN-HIGH ::= 2.65
MAX-HIGH ::= 3.25
MAX-LOW ::= 0.25
MATCH-DELTA ::= 0.10
MIN-PLATEAU-SAMPLES ::= 4

main:
  test-contract

  adcs := wiring.RP2350-ADC-PINS.map: | pin | Adc pin
  readings := adcs.map: []
  SAMPLE-COUNT.repeat:
    adcs.size.repeat: | index |
      readings[index].add (adcs[index].get --samples=SAMPLES-PER-READING)
    sleep SAMPLE-INTERVAL
  adcs.do: it.close

  failures := []
  wiring.RP2350-ADC-PINS.size.repeat: | index |
    if not (verify-channel wiring.RP2350-ADC-PINS[index] readings[index]):
      failures.add wiring.RP2350-ADC-PINS[index]
  if not failures.is-empty:
    throw "ADC: pin(s) $failures did not reproduce the DAC staircase"

  print "adc-rp2350: PASS resource contract and ADC accuracy on $(wiring.RP2350-ADC-PINS)"

test-contract:
  first-pin := wiring.RP2350-ADC-PINS[0]
  adc := Adc first-pin

  expect-throw "ALREADY_IN_USE": Adc first-pin
  expect-throw "ALREADY_IN_USE": gpio.Pin first-pin --input
  expect-throw "OUT_OF_RANGE": Adc 39
  expect-throw "OUT_OF_RANGE": Adc 48
  // The old borrowed-Pin encoding must not bypass shared pin ownership.
  expect-throw "INVALID_ARGUMENT": Adc -42
  expect-throw "INVALID_ARGUMENT": Adc first-pin --max-voltage=-0.1

  raw := adc.get --raw
  if raw < 0 or raw > 4095: throw "ADC raw sample out of 12-bit range: $raw"
  chunked := adc.get --samples=129
  if chunked < 0.0 or chunked > 3.3:
    throw "ADC chunked voltage outside nominal range: $chunked"
  expect-throw "OUT_OF_BOUNDS": adc.get --samples=0
  adc.close
  adc.close

  // close releases the shared GPIO reservation and allows either peripheral
  // to reacquire the pad.
  pin := gpio.Pin first-pin --input
  pin.close
  adc = Adc first-pin
  adc.close

verify-channel pin/int readings/List -> bool:
  sorted := readings.sort
  low := band-median sorted --low
  high := band-median sorted --high
  if low > MAX-LOW or high < MIN-HIGH or high > MAX-HIGH:
    print "adc-rp2350: GP$pin endpoints $(%.3f low)..$(%.3f high)V outside expected range -> FAIL"
    return false

  ratio := (high - low) / (DAC-LEVELS.last - DAC-LEVELS.first)
  offset := low - ratio * DAC-LEVELS.first
  pin-step := ratio * (DAC-LEVELS[1] - DAC-LEVELS[0])
  window := pin-step * 0.4
  print "adc-rp2350: GP$pin DAC $(%.3f DAC-LEVELS.first)..$(%.3f DAC-LEVELS.last)V -> ADC $(%.3f low)..$(%.3f high)V, ratio=$(%.3f ratio)"

  ok := true
  for index := 1; index < DAC-LEVELS.size - 1; index++:
    dac-voltage := DAC-LEVELS[index]
    predicted := offset + ratio * dac-voltage
    plateau := readings.filter: | reading | (reading - predicted).abs <= window
    if plateau.size < MIN-PLATEAU-SAMPLES:
      print "adc-rp2350: GP$pin DAC=$(%.2f dac-voltage)V only $plateau.size samples near $(%.3f predicted)V -> FAIL"
      ok = false
      continue
    measured := median plateau
    error := (measured - predicted).abs
    mark := error <= MATCH-DELTA ? "ok" : "FAIL"
    print "adc-rp2350: GP$pin DAC=$(%.2f dac-voltage)V predicted=$(%.3f predicted)V measured=$(%.3f measured)V error=$(%.3f error)V $mark"
    if error > MATCH-DELTA: ok = false
  return ok

band-median sorted/List --low/bool=false --high/bool=false -> float:
  count := max 1 (sorted.size / 10)
  band := low ? sorted[..count] : sorted[sorted.size - count ..]
  return median band

median values/List -> float:
  sorted := values.sort
  size := sorted.size
  if size == 0: throw "median of empty list"
  if size & 1 == 1: return sorted[size / 2]
  return (sorted[size / 2 - 1] + sorted[size / 2]) / 2.0
