// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio

TEST-PIN ::= 34
RESTRICTED-PIN ::= 0

/** Exercises RP2350B GPIO configuration, reservation, and teardown. */
main:
  expect-throw "RESTRICTED_PIN":
    gpio.Pin RESTRICTED-PIN --input
  expect-throw "OUT_OF_RANGE":
    gpio.Pin 48 --input
  last-bank0-pin := gpio.Pin 47 --input
  last-bank0-pin.close

  pin := gpio.Pin TEST-PIN --input --pull-up
  expect-throw "ALREADY_IN_USE":
    gpio.Pin TEST-PIN --input

  sleep --ms=10
  expect-equals 1 pin.get

  // SIO keeps the input path available while driving, which lets this test
  // observe push-pull and emulated open-drain levels without another wire.
  pin.configure --input --output --value=0
  expect-equals 0 pin.get
  pin.set 1
  expect-equals 1 pin.get

  pin.configure --input --output --open-drain --pull-up --value=1
  sleep --ms=1
  expect-equals 1 pin.get
  pin.set 0
  expect-equals 0 pin.get
  pin.set 1
  sleep --ms=1
  expect-equals 1 pin.get

  pin.set-open-drain false
  expect-equals 1 pin.get
  pin.set 0
  expect-equals 0 pin.get

  pin.set-pull --off
  pin.close
  // Pin.close clears its proxy; all embedded GPIO backends reject the null
  // proxy as WRONG_OBJECT_TYPE on subsequent primitive calls.
  expect-throw "WRONG_OBJECT_TYPE": pin.set 0

  // Closing returns the pin to the system-wide pool.
  reopened := gpio.Pin TEST-PIN --input --pull-up
  reopened.close
  print "gpio-resource-rp2350: PASS"
