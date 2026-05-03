// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests sending bigger chunks.

Setup: see uart-big-data-shared.toit.
*/

import expect show *
import gpio
import system
import system show platform
import uart
import .uart-big-data-shared

import .test

main:
  run-test: test

test:
  port/uart.Port := ?
  if platform == system.PLATFORM-FREERTOS:
    port = uart.Port --rx=(gpio.Pin RX1) --tx=null --baud-rate=BAUD-RATE
  else:
    port = uart.Port UART-PATH --baud-rate=BAUD-RATE

  data := #[]
  TEST-ITERATIONS.repeat: | iteration |
    while true:
      chunk := port.in.read
      data += chunk
      if data.size >= TEST-BYTES.size:
        check-read-data iteration data[..TEST-BYTES.size]
        data = data[TEST-BYTES.size..]
        break

  port.close
