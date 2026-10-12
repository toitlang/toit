// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

import ec618 show Ec618
import gpio

// Run with UART0 as the console and the UART2 peer idle. No data is sent.
main:
  routes := [[26, 25], [28, 27], [22, 21]]
  routes.size.repeat: |mapping/int|
    [[false, false], [false, true], [true, false]].do: |disabled/List|
      port := Ec618.uart2
          --mapping=mapping
          --tx-disabled=disabled[0]
          --rx-disabled=disabled[1]
          --baud-rate=115200
      try:
        2.repeat: |direction/int|
          if disabled[direction]: continue.repeat
          contender/gpio.Pin? := null
          error := catch: contender = gpio.Pin routes[mapping][direction] --input
          if contender: contender.close
          if error != "ALREADY_IN_USE":
            throw "UART2 mapping $mapping did not reserve pad $(routes[mapping][direction]): $error"
      finally:
        port.close
      // Every selected pin must become available again after closing.
      routes[mapping].do: |pad/int|
        pin := gpio.Pin pad --input
        pin.close
  print "UART2 mappings 0/1/2: duplex, TX-only, RX-only and pad release PASS"
