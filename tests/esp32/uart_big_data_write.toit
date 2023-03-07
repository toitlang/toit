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
import writer
import .uart_big_data_shared


main:
  port/uart.Port := ?
  if platform == "FreeRTOS":
    port = uart.Port --rx=null --tx=(gpio.Pin TX) --baud_rate=BAUD_RATE
  else:
    port = uart.Port UART_PATH --baud_rate=BAUD_RATE

  TEST_ITERATIONS.repeat:
    writer := writer.Writer port
    writer.write TEST_BYTES
    sleep --ms=200

  port.close
