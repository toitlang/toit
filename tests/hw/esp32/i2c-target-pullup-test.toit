// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/** Tests I2C target validation, pin ownership, and internal pull-ups. */

import expect show *
import gpio
import i2c
import system

import .test
import .variants

TEST-PIN ::= Variant.CURRENT.i2c-pullup-test-pin
OTHER-PIN ::= Variant.CURRENT.i2c-pullup-other-pin
MEASURE-PIN ::= Variant.CURRENT.i2c-pullup-measure-pin

main:
  run-test: test

test:
  test-validation

  measure := gpio.Pin MEASURE-PIN --input

  target := make-target TEST-PIN OTHER-PIN --pull-up=false
  expect-equals 0 measure.get
  expect-throw "ALREADY_IN_USE": gpio.Pin TEST-PIN
  target.close

  // Verify both SDA and SCL receive the requested pull-up.
  target = make-target TEST-PIN OTHER-PIN --pull-up
  expect-equals 1 measure.get
  target.close

  target = make-target OTHER-PIN TEST-PIN --pull-up
  expect-equals 1 measure.get
  target.close

  // The target released its pin reservation.
  pin := gpio.Pin TEST-PIN
  pin.close
  measure.close

test-validation:
  expect-throw "INVALID_ARGUMENT":
    i2c.Target --sda=TEST-PIN --scl=OTHER-PIN --address=0x42 --address-size=8
  expect-throw "INVALID_ARGUMENT":
    i2c.Target --sda=TEST-PIN --scl=OTHER-PIN --address=0x80
  expect-throw "INVALID_ARGUMENT":
    i2c.Target --sda=TEST-PIN --scl=OTHER-PIN --address=0x400 --address-size=10
  expect-throw "INVALID_ARGUMENT":
    i2c.Target --sda=TEST-PIN --scl=OTHER-PIN --address=0x42 --send-buffer-size=0
  expect-throw "INVALID_ARGUMENT":
    i2c.Target --sda=TEST-PIN --scl=OTHER-PIN --address=0x42 --receive-buffer-size=0
  expect-throw "INVALID_ARGUMENT":
    i2c.Target
        --sda=TEST-PIN
        --scl=OTHER-PIN
        --address=0x2aa
        --address-size=10
        --broadcast
  if system.architecture == system.ARCHITECTURE-ESP32:
    expect-throw "UNSUPPORTED":
      i2c.Target
          --sda=TEST-PIN
          --scl=OTHER-PIN
          --address=0x42
          --broadcast

make-target sda/int scl/int --pull-up/bool -> i2c.Target:
  return i2c.Target
      --sda=sda
      --scl=scl
      --address=0x42
      --send-buffer-size=32
      --receive-buffer-size=32
      --pull-up=pull-up
