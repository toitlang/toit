// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import expect show expect-throw
import i2c

/**
EC618 I2C ownership and argument-contract regression.

This test needs no slave. Internal pull-ups keep the empty buses idle-high.
  It checks controller exclusivity across alternate pad routings, the
  documented frequency floor, parent-closes-child lifecycle, and
  release/reacquisition. Running with the argument `leak` exits while I2C0 is
  open; a following normal run verifies forced container teardown.
*/

open-alternate-i2c0 -> i2c.Bus:
  return i2c.Bus
      --sda=(Ec618.pad 27)
      --scl=(Ec618.pad 28)
      --frequency=100_000
      --pull-up

main args:
  if not args.is-empty and args[0] == "leak":
    Ec618.i2c0 --pull-up
    print "i2c-contract: leaving I2C0 open for container-teardown coverage"
    return

  bus := Ec618.i2c0 --pull-up

  alternate-sda := Ec618.pad 27
  alternate-scl := Ec618.pad 28
  try:
    // The alternate pads still route to I2C0. Constructing the bus directly
    // proves that controller ownership is independent of the convenience
    // route and its particular pins.
    expect-throw "ALREADY_IN_USE":
      i2c.Bus
          --sda=alternate-sda
          --scl=alternate-scl
          --frequency=100_000
          --pull-up
  finally:
    alternate-sda.close
    alternate-scl.close

  expect-throw "INVALID_ARGUMENT":
    bus.device 0x40 --frequency=49_000

  slowest-round := bus.device 0x40 --frequency=50_000
  slowest-round.close

  // Bus.close owns its child lifecycle. It closes registered devices before
  // the native bus resource, so callers do not need to close each child.
  child := bus.device 0x41 --frequency=100_000
  bus.close
  expect-throw "CLOSED": child.write #[]
  child.close  // Closing an already-invalidated child remains idempotent.

  // The controller reservation, not a particular routing, was released.
  alternate := open-alternate-i2c0
  alternate.close

  print "i2c-contract: PASS ownership, parent teardown, and frequency validation"
