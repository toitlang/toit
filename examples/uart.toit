// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import uart
import gpio

/**
Example to demonstrate the use of the UART.

By connecting the RX and TX pin, this program will send data
  to itself.
*/

// Connect these two pins if you only have one ESP32-board.
RX ::= 21
TX ::= 22

main:
  port := uart.Port
      --rx=gpio.Pin RX
      --tx=gpio.Pin TX
      --baud-rate=115200

  task::
    reader := port.in
    while line := reader.read-line:
      print "Received: $line"

  writer := port.out
  10.repeat:
    writer.write "sending $it\n"
    sleep --ms=1000
