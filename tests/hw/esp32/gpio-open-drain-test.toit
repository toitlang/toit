// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests changing the open-drain setting of gpio pins.

For the setup, see the instructions near $Variant.open-drain-test-pin.
*/

import gpio
import expect show *

import .test
import .variants
import ..shared.gpio-open-drain

TEST-PIN ::= Variant.CURRENT.open-drain-test-pin
LEVEL-PIN ::= Variant.CURRENT.open-drain-level-pin
MEASURE-PIN ::= Variant.CURRENT.open-drain-measure-pin

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
