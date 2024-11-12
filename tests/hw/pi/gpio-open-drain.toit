// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests changing the open-drain setting of gpio pins.

Setup: see the shared file.
*/

import gpio
import host.os
import expect show *

import ..shared.gpio-open-drain

main:
  TEST-NAME ::= os.env.get "GPIO_TEST"
  LEVEL-NAME ::= os.env.get "GPIO_LEVEL"
  MEASURE-NAME ::= os.env.get "GPIO_MEASURE"

  if not TEST-NAME or not LEVEL-NAME or not MEASURE-NAME:
    print "One of the environment variables GPIO_TEST, GPIO_LEVEL, or GPIO_MEASURE is not set"
    exit 1

  measure-pin := gpio.Pin.linux --name=MEASURE_NAME --input
  test-pin := gpio.Pin.linux --name=TEST-NAME --output
  level-pin := gpio.Pin.linux --name=LEVEL_NAME  // Will be reconfigured.
  try:
    test-gpio
        --test-pin=test-pin
        --measure-pin=measure-pin
        --level-pin=level-pin
  finally:
    measure-pin.close
    test-pin.close
    level-pin.close
  print "All tests done"
