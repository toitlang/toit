// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the ADC HW test (device under test): verifies the ADC reads the
ESP32 DAC's exact voltages, within a delta.

The ESP32 (adc-esp32.toit) drives both ADC inputs with a known staircase
($DAC-LEVELS volts). For each channel this test samples the resulting waveform
and:
  1. self-calibrates the rig's board-to-board divider from the two extreme DAC
     levels (a 2-point fit: pin = offset + ratio * dac), and
  2. checks every intermediate DAC level lands at the predicted pin voltage,
     within $MATCH-DELTA volts.

Why calibrate instead of assuming a ratio: two resistor dividers are in play.
The EC618's *internal* ADC range divider (inside the chip) is already
compensated by the ADC driver, so adc.get returns the true *pin* voltage. But
the rig's *external* divider (resistors on the wire between the two boards) is
not — and it differs per channel — so the EC618 sees DAC * ratio with an
unknown, per-channel ratio. The 2-point fit recovers that ratio (and any ADC
offset/gain), turning "does it swing" into "does it read the right value".

Both channels must read accurately: a channel that does not swing
($LIVE-SPREAD-MIN), or whose readings are off by more than $MATCH-DELTA, fails.

Wiring: ESP32 IO25 (DAC1) -> ~2:1 divider -> EC618 ADC0 (channel 0 / AIO3, pin 3)
        ESP32 IO26 (DAC2) -> ~2:1 divider -> EC618 ADC1 (channel 1 / AIO4, pin 4)

Run via the mini-jag tester (start adc-esp32.toit on the ESP32 first so the
staircase is already running):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/adc-ec618.toit

(--port-board1 is the EC618's UART0 port — the CH340 adapter; the /dev/ttyUSBN
number swaps between sessions, so identify it by chip. See docs/ec618-hw-tests.md.)
*/

import gpio.adc show Adc

CHANNELS ::= [0, 1]
// The known staircase the ESP32 drives (adc-esp32.toit), in volts. The first
// and last are the calibration endpoints; the ones in between are verified.
DAC-LEVELS ::= [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]

SAMPLE-COUNT ::= 240               // ~30 s/channel at SAMPLE-INTERVAL (~3.5 staircase periods).
SAMPLE-INTERVAL ::= Duration --ms=125
SAMPLES-PER-READING ::= 16         // Averaged inside each Adc.get to suppress noise.

LIVE-SPREAD-MIN ::= 0.30           // V. A channel must swing at least this much to be readable.
MATCH-DELTA ::= 0.06               // V. Allowed |measured - predicted| for an intermediate level.
MIN-PLATEAU-SAMPLES ::= 4          // A trusted level needs at least this many samples near it.

main:
  failures := CHANNELS.filter: | ch/int | not (test-channel ch)
  if not failures.is-empty:
    throw "ADC: channel(s) $failures did not read the DAC accurately"
  print "adc-ec618: PASS ADC reads accurate values on all channels $CHANNELS"

// Samples one channel across the full staircase. Widest range (up to 3.8 V) so
// the divided-down DAC swing never clips; the EC618 ADC is channel-addressed
// (0 -> AIO3, 1 -> AIO4), not pin-addressed.
sample-channel ch/int -> List:
  adc := Adc.channel ch
  readings := []
  SAMPLE-COUNT.repeat:
    readings.add (adc.get --samples=SAMPLES-PER-READING)
    sleep SAMPLE-INTERVAL
  adc.close
  return readings

// Samples a channel and returns whether it reads the DAC accurately: it must
// swing (>= $LIVE-SPREAD-MIN) and every intermediate level must land within
// $MATCH-DELTA of the calibrated prediction. Prints the derived divider ratio
// and per-level measured-vs-predicted so a human can see the actual voltages.
test-channel ch/int -> bool:
  readings := sample-channel ch
  sorted := readings.sort
  spread := sorted.last - sorted.first
  if spread < LIVE-SPREAD-MIN:
    print "adc-ec618: channel $ch  spread=$(%.3f spread)V too small — no DAC swing seen (check wiring/divider) -> FAIL"
    return false

  // 2-point self-calibration from the extreme DAC levels. The lowest/highest
  // bands are the DAC=min/max plateaus; their medians absorb noise and the few
  // transition samples. predicted(dac) = offset + ratio * dac.
  m-low := band-median sorted --low
  m-high := band-median sorted --high
  dac-low := DAC-LEVELS.first
  dac-high := DAC-LEVELS.last
  ratio := (m-high - m-low) / (dac-high - dac-low)
  offset := m-low - ratio * dac-low
  // A plateau window comfortably inside half the pin-level spacing, so adjacent
  // levels never share samples (assumes ratio is not tiny; our rig is ~0.5-0.9).
  pin-step := ratio * (DAC-LEVELS[1] - DAC-LEVELS[0])
  window := pin-step * 0.4
  print "adc-ec618: channel $ch  divider ratio=$(%.3f ratio)  (DAC $(%.1f dac-low)..$(%.1f dac-high)V -> pin $(%.3f m-low)..$(%.3f m-high)V)"

  ok := true
  for i := 1; i < DAC-LEVELS.size - 1; i++:
    dac-v := DAC-LEVELS[i]
    predicted := offset + ratio * dac-v
    plateau := readings.filter: | r | (r - predicted).abs <= window
    if plateau.size < MIN-PLATEAU-SAMPLES:
      print "adc-ec618: channel $ch  DAC=$(%.2f dac-v)V  predicted $(%.3f predicted)V  only $plateau.size samples near it -> FAIL"
      ok = false
      continue
    measured := median plateau
    err := (measured - predicted).abs
    mark := err <= MATCH-DELTA ? "ok" : "FAIL"
    print "adc-ec618: channel $ch  DAC=$(%.2f dac-v)V  predicted $(%.3f predicted)V  measured $(%.3f measured)V  err $(%.3f err)V  $mark"
    if err > MATCH-DELTA: ok = false

  return ok

// Median of the lowest or highest ~10% of an already-sorted list — i.e. the
// DAC=min or DAC=max plateau.
band-median sorted/List --low/bool=false --high/bool=false -> float:
  count := max 1 (sorted.size / 10)
  band := low ? sorted[..count] : sorted[sorted.size - count ..]
  return median band

median values/List -> float:
  s := values.sort
  n := s.size
  if n == 0: throw "median of empty"
  if n & 1 == 1: return s[n / 2]
  return (s[n / 2 - 1] + s[n / 2]) / 2.0
