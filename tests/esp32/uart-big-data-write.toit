// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests sending bigger chunks.

Setup: see uart_big_data_shared.toit.
*/

import expect show *
import gpio
import system
import system show platform
import uart
import writer
import .uart-big-data-shared


main:
  port/uart.Port := ?
  if platform == system.PLATFORM-FREERTOS:
    port = uart.Port --rx=null --tx=(gpio.Pin TX) --baud-rate=BAUD-RATE
  else:
    port = uart.Port UART-PATH --baud-rate=BAUD-RATE

  TEST-ITERATIONS.repeat:
    writer := writer.Writer port
    writer.write TEST-BYTES
    sleep --ms=200

  port.close
  print "done"
