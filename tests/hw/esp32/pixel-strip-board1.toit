// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// ARG: rmt uart

import expect show *
import gpio
import pixel_strip show PixelStrip

import .pixel-strip-shared
import .test

main args:
  run-test:
    backend := args[0]
    expect (["rmt", "uart"].contains backend)

    ready := gpio.Pin READY-PIN --input --pull-down
    strip/PixelStrip := ?
    if backend == "rmt":
      strip = PixelStrip.rmt PIXELS --pin=DATA-PIN
    else:
      strip = PixelStrip.uart PIXELS --pin=DATA-PIN

    try:
      3.repeat:
        ready.wait-for 1
        strip.output RED GREEN BLUE
        // UART output is buffered. Give it time to reach the wire before the
        //   next frame or close tears down the peripheral.
        sleep --ms=1
        ready.wait-for 0
    finally:
      strip.close
      ready.close
