// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the ADC HW test (device under test).

Samples both EC618 ADC channels while the ESP32 (adc-esp32.toit) drives a
square wave into them through voltage dividers, and confirms each channel
tracks the stimulus (a clear min/max spread).

One ADC pin on this particular board may be dead, so the test passes as long
as at least one channel tracks; it reports any stuck channel so the board can
be flagged/replaced.

Wiring: ESP32 IO25 (DAC1) -> divider -> EC618 ADC0 (channel 0 / AIO3, pin 3)
        ESP32 IO26 (DAC2) -> divider -> EC618 ADC1 (channel 1 / AIO4, pin 4)

Run via the mini-jag tester (start adc-esp32.toit on the ESP32 first so the
DACs are already swinging):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/adc-ec618.toit

(--port-board1 is the EC618's UART0 port — the CH340 adapter; the /dev/ttyUSBN
number swaps between sessions, so identify it by chip. See docs/ec618-hw-tests.md.)
*/

import gpio.adc show Adc

CHANNELS ::= [0, 1]
SAMPLE-COUNT ::= 60
SAMPLE-INTERVAL ::= Duration --ms=200   // ~12 s window per channel; spans several DAC toggles.
SPREAD-THRESHOLD ::= 0.3                 // Volts. A live channel swings >1 V; a dead one barely moves.

main:
  tracked := {:}  // channel -> bool
  CHANNELS.do: | ch/int |
    // Widest range (up to 3.8 V) so the divided-down DAC swing never clips.
    // EC618 ADC is channel-addressed (0 -> AIO3, 1 -> AIO4), not pin-addressed.
    adc := Adc.channel ch
    first := adc.get --samples=8
    min := first
    max := first
    (SAMPLE-COUNT - 1).repeat:
      sleep SAMPLE-INTERVAL
      v := adc.get --samples=8
      if v < min: min = v
      if v > max: max = v
    adc.close
    spread := max - min
    is-live := spread >= SPREAD-THRESHOLD
    tracked[ch] = is-live
    print "adc-ec618: channel $ch  min=$(%.3f min)V  max=$(%.3f max)V  spread=$(%.3f spread)V  tracked=$is-live"

  live := CHANNELS.filter: | ch | tracked[ch]
  dead := CHANNELS.filter: | ch | not tracked[ch]
  if not dead.is-empty:
    print "adc-ec618: NOTE channel(s) $dead did not track — likely the known-dead ADC pin"
  if live.is-empty:
    print "adc-ec618: FAIL no channel tracked the DAC; ADC not working on either pin"
    throw "ADC: no channel tracked the DAC stimulus"
  print "adc-ec618: PASS ADC tracks the DAC on channel(s) $live"
