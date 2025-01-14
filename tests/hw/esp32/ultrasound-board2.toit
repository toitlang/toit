// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import hc-sr04

import .test
import .variants

main:
  run-test: test

test:
  echo := gpio.Pin.in Variant.CURRENT.board2-hc-sr04-echo-pin
  trigger := gpio.Pin.out Variant.CURRENT.board2-hc-sr04-trigger-pin
  driver := hc-sr04.Driver --echo=echo --trigger=trigger

  5.repeat:
    distance := driver.read-distance
    print distance
    // Requires the board to be pointing towards a wall with at most 1m distance.
    expect 0 < distance < 1000
    sleep --ms=200
