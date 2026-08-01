// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// ARG: rmt

import expect show *
import gpio
import pixel_strip show PixelStrip

import .pixel-strip-shared
import .test

main args:
  run-test:
    expect-equals "rmt" args[0]

    data := gpio.Pin.out DATA-PIN
    ready := gpio.Pin READY-PIN --input --pull-down
    strip := PixelStrip.rmt PIXELS --pin=data

    try:
      ready.wait-for 1
      strip.output RED GREEN BLUE
    finally:
      strip.close
      data.close
      ready.close
