// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-throw
import gpio
import i2c

/**
RP2350 I2C argument, ownership, and lifecycle regression.

This test needs no target. Internal pull-ups keep the empty buses idle-high.
*/

open-i2c0 -> i2c.Bus:
  return i2c.Bus --sda=4 --scl=5 --frequency=100_000 --pull-up

open-i2c1 -> i2c.Bus:
  return i2c.Bus --sda=10 --scl=11 --frequency=100_000 --pull-up

main:
  print "i2c-contract-rp2350: argument validation"
  // Only numeric GP identifiers are accepted. A gpio.Pin is encoded as a
  // negative borrowed-pin value by the compatibility layer and is rejected.
  borrowed := gpio.Pin 6 --input
  try:
    expect-throw "INVALID_ARGUMENT":
      i2c.Bus --sda=borrowed --scl=5 --frequency=100_000  // @no-warn
  finally:
    borrowed.close
  expect-throw "INVALID_ARGUMENT":
    i2c.Bus --sda=-5 --scl=5 --frequency=100_000
  expect-throw "INVALID_ARGUMENT":
    i2c.Bus --sda=5 --scl=4 --frequency=100_000
  expect-throw "INVALID_ARGUMENT":
    i2c.Bus --sda=4 --scl=7 --frequency=100_000
  expect-throw "INVALID_ARGUMENT":
    i2c.Bus --sda=48 --scl=5 --frequency=100_000
  expect-throw "PERMISSION_DENIED":
    i2c.Bus --sda=0 --scl=1 --frequency=100_000

  bus0 := open-i2c0
  bus1 := open-i2c1
  print "i2c-contract-rp2350: both controllers reserved"
  try:
    // GP8/9 are an alternate route to I2C0, so the controller reservation
    // rejects them even though those particular GPIOs are free.
    expect-throw "ALREADY_IN_USE":
      i2c.Bus --sda=8 --scl=9 --frequency=100_000 --pull-up
    expect-throw "ALREADY_IN_USE": gpio.Pin 4 --input
    expect-throw "ALREADY_IN_USE": gpio.Pin 5 --input

    expect-throw "INVALID_ARGUMENT":
      bus0.device 0x42 --frequency=1
    expect-throw "INVALID_ARGUMENT":
      bus0.device 0x42 --frequency=1_000_001
    expect-throw "INVALID_ARGUMENT":
      bus0.device 0x142 --address-bit-size=10

    // RP2350's DesignWare command FIFO cannot emit an address-only transfer.
    expect-throw "UNIMPLEMENTED": bus0.test 0x42
  finally:
    bus1.close

  // Bus.close owns its child lifecycle and releases both GPIOs and I2C0.
  child := bus0.device 0x42 --frequency=100_000
  bus0.close
  expect-throw "CLOSED": child.write #[0]
  child.close

  pin4 := gpio.Pin 4 --input
  pin5 := gpio.Pin 5 --input
  pin4.close
  pin5.close

  alternate := i2c.Bus --sda=8 --scl=9 --frequency=100_000 --pull-up
  alternate.close
  reopened := open-i2c0
  reopened.close

  print "i2c-contract-rp2350: PASS"
