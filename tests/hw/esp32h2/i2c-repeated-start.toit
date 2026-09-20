// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system
import uart
import .buses as buses
import .wiring

main:
  h2 := system.architecture == system.ARCHITECTURE-ESP32H2
  port := uart.Port
      --rx=(h2 ? H2-RX : HELPER-RX)
      --tx=(h2 ? H2-TX : HELPER-TX)
      --baud-rate=115200
  if h2: sleep --ms=1500
  try:
    [50_000, 100_000].do: | frequency |
      // Exercise both sides of the controller's 32-byte FIFO boundaries.
      [17, 19, 30, 31, 32, 33, 62, 63, 64, 65, 94, 95, 96, 127, 128, 129, 255, 256, 1024].do: | size |
        print "Repeated-start write size $size frequency=$frequency"
        buses.i2c-case port h2 frequency size
  finally:
    port.close
  print "All tests done"
