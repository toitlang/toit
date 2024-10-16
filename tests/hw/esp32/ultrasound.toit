// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import hc-sr04

main:
  echo := gpio.Pin.in 19
  trigger := gpio.Pin.out 18
  driver := hc-sr04.Driver --echo=echo --trigger=trigger

  while true:
    print "The distance is: $driver.read-distance mm"
    sleep --ms=2_000
