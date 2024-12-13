// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import hc-sr04

import .test

main:
  run-test: test

test:
  echo := gpio.Pin.in 19
  trigger := gpio.Pin.out 18
  driver := hc-sr04.Driver --echo=echo --trigger=trigger

  5.repeat:
    distance := driver.read-distance
    // Requires the board to be pointing towards a wall with at most 1m distance.
    expect 0 < distance < 1000
    sleep --ms=200
