// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio.dac show Dac

import .wiring as wiring

/**
ESP32 half of the ADC HW test: drives the EC618 ADC inputs with a known
  staircase.

Steps both DACs through a fixed list of voltages ($LEVELS), holding each for
  $HOLD, and loops for $DURATION. The EC618 half (adc-ec618.toit) samples the
  resulting waveform, self-calibrates the board-to-board divider from the two
  extreme levels, and then checks that every intermediate level lands at the
  expected voltage (see that file).

Two resistor dividers sit between the ESP32 DAC and what the EC618 reads:
  - an EXTERNAL ~2:1 divider on the rig wiring (these resistors, between the
    boards) — the EC618 ADC pin sees roughly DAC/2; the EC618 test derives the
    exact ratio empirically per channel.
  - the EC618's INTERNAL ADC range divider (inside the chip) — already
    compensated by the EC618 ADC driver, so adc.get returns the true pin volts.
  So a 1.0 V DAC step shows up as ~0.5 V at the EC618; the test verifies that.

*/

// A clean 0.5 V staircase. 0.0 and 3.0 V are the calibration endpoints; the
// EC618 verifies the values in between. With the ~2:1 divider, 3.0 V maps to
// ~1.5 V at the EC618 AIO pin (well within its 3.8 V range).
LEVELS ::= [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
HOLD ::= Duration --ms=1200
// Long enough to outlast the EC618's install + several-period sampling of both
// channels (it samples ~30 s/channel and starts after this one is up).
DURATION ::= Duration --s=180

main:
  dac1 := Dac wiring.ESP32-ADC0-DAC-PIN
  dac2 := Dac wiring.ESP32-ADC1-DAC-PIN
  print "adc-esp32: staircase $LEVELS V on IO$(wiring.ESP32-ADC0-DAC-PIN)+IO$(wiring.ESP32-ADC1-DAC-PIN), $(HOLD.in-ms)ms/step, for $(DURATION.in-s)s"
  deadline := Time.monotonic-us + DURATION.in-us
  i := 0
  while Time.monotonic-us < deadline:
    v := LEVELS[i % LEVELS.size]
    dac1.set v
    dac2.set v
    print "adc-esp32: DAC=$(%.2f v)V"
    sleep HOLD
    i++
  dac1.set 0.0
  dac2.set 0.0
  dac1.close
  dac2.close
  print "adc-esp32: done"
