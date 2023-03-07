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
import .uart_big_data_shared

main:
  port/uart.Port := ?
  if platform == "FreeRTOS":
    port = uart.Port --rx=(gpio.Pin RX) --tx=null --baud_rate=BAUD_RATE
  else:
    port = uart.Port UART_PATH --baud_rate=BAUD_RATE

  data := #[]
  TEST_ITERATIONS.repeat:
    while true:
      chunk := port.read
      data += chunk
      if data.size >= TEST_BYTES.size:
        check_read_data data[..TEST_BYTES.size]
        data = data[TEST_BYTES.size..]
        break

  port.close
