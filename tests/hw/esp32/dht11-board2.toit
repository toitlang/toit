// Copyright (C) 2025 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import dhtxx.dht11

import .test
import .variants

main:
  run-test: test

test:
  data := gpio.Pin Variant.CURRENT.board2-dht11-pin
  driver := dht11.Dht11 data

  2.repeat:
    measurements := driver.read
    print measurements
    expect 12 < measurements.temperature < 35
    expect 15 < measurements.humidity < 80
    sleep --ms=500
