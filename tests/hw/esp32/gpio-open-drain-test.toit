// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests changing the open-drain setting of gpio pins.

Setup:
Connect pin 18 and 19 with a 330 Ohm (or any other 300-1K) resistor.
Connect pin 18 to pin 34.
Connect pin 18 to GND with a 1M Ohm resistor (or any other big number).
*/

import gpio
import expect show *

import .test
import ..shared.gpio-open-drain

TEST-PIN ::= 18
LEVEL-PIN ::= 19
MEASURE-PIN ::= 34

main:
  run-test: test

test:
  measure-pin := gpio.Pin MEASURE-PIN --input
  test-pin := gpio.Pin TEST-PIN --output
  level-pin := gpio.Pin LEVEL-PIN  // Will be reconfigured.
  try:
    test-gpio
        --test-pin=test-pin
        --measure-pin=measure-pin
        --level-pin=level-pin
  finally:
    measure-pin.close
    test-pin.close
    level-pin.close
