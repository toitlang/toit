// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
EC618 half of the AON-pad GPIO-input regression.

The ESP32 drives PAD44 and PAD47 through every two-bit pattern. A framed UART1 exchange acknowledges each transition before this side samples both inputs, so the test has no timing window or inferred wire identity.
*/

CONTROL-TIMEOUT-MS ::= 15_000

main:
  control-owner := rig.ec618-uart 1 115200
  control := FramedChannel control-owner.port
  first := Ec618.gpio wiring.EC618-GPIO24-NUM --input
  second := Ec618.gpio wiring.EC618-GPIO27-NUM --input
  failures := []

  try:
    control.send "HELLO"
    control.expect "READY" --timeout-ms=120_000

    ["00", "10", "01", "11", "00"].do: | pattern/string |
      control.send "SET $pattern"
      control.expect "SET $pattern" --timeout-ms=CONTROL-TIMEOUT-MS
      actual := "$(first.get)$(second.get)"
      print "gpio-aon-input-ec618: expected=$pattern actual=$actual"
      if actual != pattern: failures.add "$pattern->$actual"

    control.send "Q"
    control.expect "BYE" --timeout-ms=CONTROL-TIMEOUT-MS

    if not failures.is-empty:
      throw "AON GPIO input failed: $failures"
    print "gpio-aon-input-ec618: PASS PAD44/PAD47 input and wire identity"
  finally:
    second.close
    first.close
    control-owner.close
