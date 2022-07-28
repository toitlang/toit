/*  */// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests gpio configurations.

Setup:
Connect pin 16 to pin 26, optionally with a 330 Ohm resistor to avoid short circuits.
*/

import gpio
import expect show *

PIN1 ::= 16
PIN2 ::= 26

should_reconfigure := true

main:
  pin1 := gpio.Pin PIN1
  pin2 := gpio.Pin PIN2

  pin1.configure --output
  pin2.configure --input

  expect_equals 0 pin2.get
  pin1.set 1
  expect_equals 1 pin2.get

  pin1.configure --input --pull_down
  expect_equals 0 pin1.get
  expect_equals 0 pin2.get

  pin1.configure --input --pull_up
  expect_equals 1 pin1.get
  expect_equals 1 pin2.get

  expect_throw "INVALID_ARGUMENT": pin1.configure --input --pull_up --pull_down
  expect_throw "INVALID_ARGUMENT": pin1.configure --output --pull_up --pull_down

  pin1.configure --input --pull_up
  pin2.configure --output
  // Override the pull up of pin1
  pin2.set 0
  expect_equals 0 pin1.get
  pin2.set 1
  expect_equals 1 pin1.get

  pin1.configure --input --pull_down
  pin2.configure --output
  pin2.set 0
  expect_equals 0 pin1.get
  // Override the pull down of pin1
  pin2.set 1
  expect_equals 1 pin1.get

  pin1.configure --input --pull_up
  pin2.configure --input --output --open_drain

  // Open-drain automatically starts with a high output.
  expect_equals 1 pin1.get
  expect_equals 1 pin2.get

  pin1.configure --input --output --open_drain --pull_up

  expect_equals 1 pin1.get
  expect_equals 1 pin2.get

  pin1.set 0
  expect_equals 0 pin1.get
  expect_equals 0 pin2.get

  pin1.set 1
  expect_equals 1 pin1.get
  expect_equals 1 pin2.get

  pin2.set 0
  expect_equals 0 pin1.get
  expect_equals 0 pin2.get

  pin2.set 1
  expect_equals 1 pin1.get
  expect_equals 1 pin2.get

  pin1.set 0
  pin2.set 0
  expect_equals 0 pin1.get
  expect_equals 0 pin2.get

  pin1.close
  pin2.close

  print "done"
