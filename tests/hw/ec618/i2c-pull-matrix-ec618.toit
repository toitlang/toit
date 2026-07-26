// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import i2c

import .framed-control show FramedChannel
import .uart-rig as rig

/**
Checks I2C0 with no pull-ups, EC618 pull-ups, and ESP32 pull-ups.

The I2C address is deliberately absent. Each probe must return false promptly,
  and the two pulled-up phases must report idle-high wires. Running the
  no-pull phase first and then both working phases also verifies that a dead
  bus does not wedge the controller.
*/

ABSENT-ADDRESS ::= 0x42
PROBE-TIMEOUT-MS ::= 100
MAX-PROBE-MS ::= 1_000

failures := []

main:
  control-owner := rig.ec618-uart 2 115200
  control := FramedChannel control-owner.port
  control.send "HELLO"
  control.expect "READY" --timeout-ms=120_000

  // Neither side supplies a pull-up. The exact floating levels are not a
  // contract; only bounded failure and subsequent recovery are.
  control.send "P 0"
  expect-prefix control "P 0 "
  run-probe "no-pulls" false

  // Only the ESP32 supplies pull-ups.
  control.send "P 1"
  expect-high control "P 1"
  run-probe "esp32-pulls" false

  // Only the EC618 supplies pull-ups.
  control.send "P 0"
  expect-prefix control "P 0 "
  bus := Ec618.i2c0 --pull-up
  try:
    control.send "L"
    expect-high control "L"
    probe "ec618-pulls" bus
  finally:
    bus.close

  control.send "Q"
  control.expect "BYE" --timeout-ms=10_000
  control-owner.close

  if not failures.is-empty:
    print "i2c-pull-matrix-ec618: FAIL $failures"
    throw "I2C pull matrix failed: $failures"
  print "i2c-pull-matrix-ec618: PASS no-pull failure and both pull-up owners"

run-probe label/string local-pull-up/bool -> none:
  bus := Ec618.i2c0 --pull-up=local-pull-up
  try:
    probe label bus
  finally:
    bus.close

probe label/string bus/i2c.Bus -> none:
  present := true
  duration := Duration.of:
    present = bus.test ABSENT-ADDRESS --timeout-ms=PROBE-TIMEOUT-MS
  check (not present) "$(label)-absent-address"
  check (duration.in-ms <= MAX-PROBE-MS)
      "$(label)-bounded-$(duration.in-ms)ms"

expect-prefix control/FramedChannel prefix/string -> none:
  reply := control.receive --timeout-ms=10_000
  check (reply.starts-with prefix) "reply-$prefix"

expect-high control/FramedChannel prefix/string -> none:
  reply := control.receive --timeout-ms=10_000
  check (reply == "$prefix 1 1") "$(prefix)-idle-high"

check ok/bool label/string -> none:
  print "i2c-pull-matrix-ec618: $label $(ok ? "ok" : "FAIL")"
  if not ok: failures.add label
