// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import monitor

TEST-PIN ::= 34
TRANSITIONS ::= 100

/** Exercises RP2350 GPIO level interrupts and deferred VM event dispatch. */
main:
  pin := gpio.Pin TEST-PIN --input --output --value=0
  ready := monitor.Channel 1
  done := monitor.Latch
  failure := null

  task::
    failure = catch:
      TRANSITIONS.repeat: | i |
        expected := (i + 1) & 1
        ready.send i
        pin.wait-for expected
    critical-do: done.set true

  TRANSITIONS.repeat: | i |
    expected := (i + 1) & 1
    expect-equals i ready.receive
    // Give wait-for time to arm the level interrupt before changing SIO.
    sleep --ms=2
    pin.set expected

  with-timeout --ms=5_000: done.get
  if failure: throw failure

  // A stable low level must not satisfy a wait for high.
  pin.set 0
  quiet := catch:
    with-timeout --ms=100: pin.wait-for 1
  expect-equals DEADLINE-EXCEEDED-ERROR quiet

  pin.close
  print "gpio-interrupt-rp2350: PASS $TRANSITIONS transitions"
