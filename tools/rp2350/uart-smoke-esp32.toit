// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.

// Tests both UART wires against toolchains/rp2350/bringup.c's binary echo.
import uart
import .wiring as wiring

main:
  port := uart.Port --tx=wiring.UART-TX-PIN --rx=wiring.UART-RX-PIN --baud-rate=115200
  try:
    16.repeat: | round/int |
      payload := ByteArray 256
      payload.size.repeat: | i/int |
        payload[i] = (i + round * 17) & 0xff
      with-timeout --ms=5_000:
        port.out.write payload
        port.out.flush
        received := 0
        while received < payload.size:
          chunk := port.in.read
          if not chunk: throw "UART closed"
          chunk.size.repeat: | i/int |
            if received >= payload.size or chunk[i] != payload[received]:
              throw "UART mismatch in round $round at byte $received"
            received++
    print "rp2350 UART: PASS 4096 bytes, ESP$(wiring.UART-TX-PIN) -> GP1 -> GP16 -> ESP$(wiring.UART-RX-PIN), 115200 8N1"
  finally:
    port.close
