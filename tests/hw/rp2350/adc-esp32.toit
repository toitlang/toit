// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio.dac show Dac

import .wiring as wiring

/**
ESP32 stimulus half of the RP2350B ADC hardware test.

Both DACs repeatedly drive the same slow staircase. The rig connects DAC25 to
  RP GP40 through 4 kohm and DAC26 to RP GP41 through 10 kohm. Those resistors
  are series source resistors, not voltage dividers, so both ADC pins should
  follow the DAC voltage.

Start this program before adc-rp2350.toit. Its long duration leaves time to
  install and start the RP2350 test without synchronizing the boards.
*/

LEVELS ::= [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
HOLD ::= Duration --ms=1200
DURATION ::= Duration --s=120

main:
  dac0 := Dac wiring.ESP32-DAC-PINS[0]
  dac1 := Dac wiring.ESP32-DAC-PINS[1]
  print "adc-esp32: staircase $LEVELS V on IO$(wiring.ESP32-DAC-PINS[0])+IO$(wiring.ESP32-DAC-PINS[1]), $(HOLD.in-ms)ms/step"

  deadline := Time.monotonic-us + DURATION.in-us
  index := 0
  while Time.monotonic-us < deadline:
    voltage := LEVELS[index % LEVELS.size]
    dac0.set voltage
    dac1.set voltage
    sleep HOLD
    index++

  dac0.set 0.0
  dac1.set 0.0
  dac0.close
  dac1.close
  print "adc-esp32: done"
