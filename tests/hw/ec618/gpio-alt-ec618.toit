// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618

import .framed-control show FramedChannel
import .uart-rig as rig

/**
EC618 half of the alternate-pad GPIO output test.

GPIO14 and GPIO15 have primary ALT0 pads 29/30 and alternate ALT4 pads 13/14.
  The alternate pads are wired to ESP32 IO17/18 on the rig. A framed UART1
  exchange makes the helper sample every two-bit output pattern, proving both
  physical-pad identities without timing windows.
*/

main:
  control-owner := rig.ec618-uart 1 115200
  control := FramedChannel control-owner.port
  gpio14 := Ec618.gpio 14 --alt
  gpio15 := Ec618.gpio 15 --alt
  gpio14.configure --output --value=0
  gpio15.configure --output --value=0

  try:
    control.send "HELLO"
    control.expect "READY" --timeout-ms=120_000

    ["00", "10", "01", "11", "00"].do: | pattern/string |
      gpio14.set pattern[0] - '0'
      gpio15.set pattern[1] - '0'
      control.send "CHECK $pattern"
      control.expect "READ $pattern" --timeout-ms=15_000

    control.send "Q"
    control.expect "BYE" --timeout-ms=15_000
    print "gpio-alt-ec618: PASS GPIO14/PAD13 and GPIO15/PAD14"
  finally:
    gpio15.close
    gpio14.close
    control-owner.close
