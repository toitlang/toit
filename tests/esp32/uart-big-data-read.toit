// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests sending bigger chunks.

Setup: see uart_big_data_shared.toit.
*/

import expect show *
import gpio
import uart
import .uart-big-data-shared

main:
  port/uart.Port := ?
  if platform == "FreeRTOS":
    port = uart.Port --rx=(gpio.Pin RX) --tx=null --baud-rate=BAUD-RATE
  else:
    port = uart.Port UART-PATH --baud-rate=BAUD-RATE

  data := #[]
  TEST-ITERATIONS.repeat:
    while true:
      chunk := port.read
      data += chunk
      if data.size >= TEST-BYTES.size:
        check-read-data data[..TEST-BYTES.size]
        data = data[TEST-BYTES.size..]
        break

  port.close
  print "done"
