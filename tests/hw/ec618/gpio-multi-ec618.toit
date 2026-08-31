// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
EC618 half of the concurrent GPIO-output regression.

Pair with gpio-multi-esp32.toit. Three physically observed pads remain open
  while several simultaneous output patterns are checked. Closing the middle
  pad must release only that wire; both surviving outputs must keep driving.

Running with argument `leak` exits with PAD26 open. A following normal run
  verifies that forced container teardown returned its reservations.
*/

CONTROL-BAUD ::= 115200
CONTROL-TIMEOUT-MS ::= 15_000

expect-throws expected/string [block] -> none:
  caught := catch: block.call
  if caught == null: throw "expected '$expected' to be thrown"
  if caught is string and caught.contains expected: return
  throw "expected '$expected', got: $caught"

verify control/FramedChannel pins/List pattern/string -> none:
  pattern.size.repeat: | i/int |
    pins[i].set pattern[i] - '0'
  control.send "CHECK $pattern"
  control.expect "SEEN $pattern" --timeout-ms=CONTROL-TIMEOUT-MS

main args:
  if not args.is-empty and args[0] == "leak":
    gpio.Pin wiring.EC618-GPIO11-PAD --output --value=1
    print "gpio-multi: leaving PAD$(wiring.EC618-GPIO11-PAD) open for container-teardown coverage"
    return

  // PAD27 and PAD11 are distinct physical pads, but both route GPIO12.
  // They must not be owned independently because their data, direction, and
  // interrupt registers are the same controller bit.
  primary := gpio.Pin 27
  alternate := gpio.Pin 11
  primary.configure --output
  expect-throws "ALREADY_IN_USE":
    alternate.configure --output
  primary.close
  alternate.configure --output
  alternate.close

  control-owner := rig.ec618-uart 1 CONTROL-BAUD
  control := FramedChannel control-owner.port
  pins := [
    gpio.Pin wiring.EC618-GPIO11-PAD --output --value=1,
    gpio.Pin wiring.EC618-GPIO24-PAD --output --value=0,
    gpio.Pin wiring.EC618-GPIO27-PAD --output --value=0,
  ]
  middle-open := true

  try:
    control.send "HELLO"
    control.expect "READY" --timeout-ms=CONTROL-TIMEOUT-MS

    // Initial values must be visible without a separate set.
    verify control pins "100"
    expect-throws "ALREADY_IN_USE":
      gpio.Pin wiring.EC618-GPIO11-PAD
    expect-throws "INVALID_ARGUMENT":
      pins[0].set 2

    ["010", "001", "111", "000", "101"].do: | pattern/string |
      verify control pins pattern

    // Releasing one pad must neither close nor reconfigure the others. The
    // helper's pull-down makes the released middle wire read deterministically.
    pins[1].close
    middle-open = false
    pins[0].set 1
    pins[2].set 1
    control.send "CHECK 101"
    control.expect "SEEN 101" --timeout-ms=CONTROL-TIMEOUT-MS

    control.send "Q"
    control.expect "BYE" --timeout-ms=CONTROL-TIMEOUT-MS
    print "gpio-multi: PASS concurrent outputs stay independent"
  finally:
    pins[0].close
    if middle-open: pins[1].close
    pins[2].close
    control-owner.close
