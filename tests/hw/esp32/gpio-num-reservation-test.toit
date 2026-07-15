// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the GPIO-number peripheral API.

When a peripheral is given an integer GPIO number (the new API) it reserves the
  pin itself and releases it again when it is closed. When given a (deprecated)
  $gpio.Pin, the pin keeps its own reservation.

This test does not need any external wiring.
*/

import expect show *
import gpio
import rmt

import .test
import .variants

PIN ::= Variant.CURRENT.rmt-pin1

main:
  run-test: test

test:
  // New integer API: the peripheral reserves the pin.
  out := rmt.Out PIN --resolution=1_000_000
  // The pin is now taken: opening it as a gpio.Pin must fail.
  expect-throw "ALREADY_IN_USE": gpio.Pin PIN
  out.close
  // After closing the peripheral the pin is free again.
  pin := gpio.Pin PIN
  pin.close

  // The pin can be handed to a new peripheral after the first one released it.
  out2 := rmt.Out PIN --resolution=1_000_000
  out2.close

  // Deprecated path: the gpio.Pin owns the reservation; the peripheral reuses
  // it without taking ownership.
  deprecated-pin := gpio.Pin PIN
  out3 := rmt.Out deprecated-pin --resolution=1_000_000
  out3.close
  // Closing the peripheral must not release a pin it doesn't own.
  expect-throw "ALREADY_IN_USE": gpio.Pin PIN
  deprecated-pin.close
  // Now it is free again.
  pin2 := gpio.Pin PIN
  pin2.close
