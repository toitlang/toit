// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ds18b20
import expect show *
import gpio

import .test
import .variants

main:
  run-test: test

test:
  data := gpio.Pin Variant.CURRENT.board2-ds18b20-pin
  driver := ds18b20.Ds18b20 data

  2.repeat:
    temperature := driver.read-temperature
    print temperature
    expect 12 < temperature < 35
    sleep --ms=200
